import Foundation
import Security

// MARK: - Directory AI settings (UserDefaults-backed, no secrets)

/// User-configurable Directory AI search preferences. Only the API key itself
/// lives in the Keychain — everything else here is non-sensitive.
public enum DirectorySearchSettings {
    public static let isAIEnabledKey = "fluxdl_directory_ai_enabled"
    public static let modelKey = "fluxdl_directory_ai_model"
    public static let useAIInterpretationKey = "fluxdl_directory_ai_interpret"

    /// Master switch for AI query interpretation. Local search always works.
    public static var isAIEnabled: Bool {
        get { UserDefaults.standard.object(forKey: isAIEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: isAIEnabledKey) }
    }

    /// Current stable, low-latency query-understanding model (GA, cheap,
    /// fast). Editable in the AI Search settings sheet.
    public static var geminiModel: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "gemini-3.5-flash-lite" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// Whether Gemini may refine the user's query into structured filters.
    public static var usesAIInterpretation: Bool {
        get { UserDefaults.standard.object(forKey: useAIInterpretationKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: useAIInterpretationKey) }
    }
}

// MARK: - API key storage (Keychain only — never UserDefaults, never source)

public protocol DirectoryAIKeychainStoring: AnyObject {
    func apiKey() -> String?
    func saveAPIKey(_ key: String)
    func deleteAPIKey()
}

/// Stores the user's Gemini API key in the iOS Keychain. Mirrors
/// `ProxyKeychainStore` so the key is never persisted in plain text.
public final class DirectoryAIKeychainStore: DirectoryAIKeychainStoring {
    private let service = "com.rakib.FluxDL.aikey"
    private let account = "gemini"

    public init() {}

    public func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)
        return key?.isEmpty == false ? key : nil
    }

    public func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(trimmed.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    public func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - AI provider protocol

/// Query-understanding provider. Local search never depends on it — every
/// failure (missing key, network, timeout, malformed output) falls back to
/// plain local matching.
public protocol DirectorySearchAIProviding: AnyObject {
    var isConfigured: Bool { get }
    func interpret(query: String) async throws -> DirectorySearchQuery
}

public enum GeminiDirectorySearchError: LocalizedError, Sendable {
    case missingAPIKey
    case timeout
    case invalidResponse
    case httpStatus(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "AI unavailable — no API key configured"
        case .timeout: return "AI request timed out"
        case .invalidResponse: return "AI returned an unreadable response"
        case .httpStatus(let code): return "AI service error (HTTP \(code))"
        case .network(let detail): return "AI network error: \(detail)"
        }
    }
}

// MARK: - Gemini REST provider

/// Native Swift Gemini client (plain `URLSession`, no SDK) used ONLY for
/// query understanding. It talks directly to the Gemini public API and never
/// touches the directory HTTP client, the proxy stack or any directory server.
///
/// Structured output is enforced twice:
/// 1. `generationConfig.responseSchema` asks Gemini for the exact JSON shape.
/// 2. The response is decoded into `DirectorySearchIntent`; any malformed or
///    unexpected payload throws `invalidResponse` and the caller falls back.
public final class GeminiDirectorySearchService: DirectorySearchAIProviding {

    private let session: URLSession
    private let keychain: DirectoryAIKeychainStoring
    public let model: String
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        keychain: DirectoryAIKeychainStoring = DirectoryAIKeychainStore(),
        model: String = DirectorySearchSettings.geminiModel,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        timeout: TimeInterval = 12
    ) {
        self.session = session
        self.keychain = keychain
        self.model = model
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public var isConfigured: Bool {
        keychain.apiKey() != nil
    }

    public func interpret(query: String) async throws -> DirectorySearchQuery {
        guard let apiKey = keychain.apiKey() else {
            throw GeminiDirectorySearchError.missingAPIKey
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GeminiDirectorySearchError.invalidResponse
        }

        let endpoint = baseURL.appendingPathComponent("models/\(model):generateContent")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try makeRequestBody(query: trimmed)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw GeminiDirectorySearchError.timeout
        } catch let error as URLError {
            throw GeminiDirectorySearchError.network(error.localizedDescription)
        } catch {
            throw GeminiDirectorySearchError.network(error.localizedDescription)
        }

        let intent = try decodeIntent(from: data)
        return DirectorySearchQueryConverter.convert(intent)
    }

    // MARK: Request body

    private func makeRequestBody(query: String) throws -> Data {
        let systemInstruction =
            """
            You interpret file search queries for an Open Directory file browser. \
            Convert the user's natural language into structured search filters. \
            Follow these rules strictly:
            - textTerms: the meaningful lowercase search words (no stopwords, no "find/show/me/a/the/of/in").
            - year: a 4-digit year only when one is clearly intended (e.g. 1998, 2024).
            - resolution: one of 480p, 720p, 1080p, 1440p, 2160p, 8k.
            - mediaType: one of "video", "audio", "image", "archive", "document", or null.
            - fileExtension: a plain extension like "mkv" or "mp4", or null.
            - minSizeGB / maxSizeGB: a size constraint only when the user asks for files "larger than" or "smaller than" a size.
            - sort: "relevance", "sizeDescending" or "dateDescending", or null.
            Empty fields must be null. Never invent filters the user did not ask for.
            """

        let payload: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [
                ["parts": [["text": query]]]
            ],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "textTerms": ["type": "ARRAY", "items": ["type": "STRING"]],
                        "year": ["type": "INTEGER"],
                        "resolution": ["type": "STRING"],
                        "mediaType": ["type": "STRING"],
                        "fileExtension": ["type": "STRING"],
                        "minSizeGB": ["type": "NUMBER"],
                        "maxSizeGB": ["type": "NUMBER"],
                        "sort": ["type": "STRING"]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: Strict response decoding

    private func decodeIntent(from data: Data) throws -> DirectorySearchIntent {
        guard let envelope = try? JSONDecoder().decode(GeminiResponse.self, from: data),
              let text = envelope.candidates?.first?.content.parts.first?.text,
              !text.isEmpty,
              let intentData = text.data(using: .utf8) else {
            throw GeminiDirectorySearchError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(DirectorySearchIntent.self, from: intentData)
        } catch {
            throw GeminiDirectorySearchError.invalidResponse
        }
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }
                let parts: [Part]
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }
}

/// Converts a validated `DirectorySearchIntent` into the search engine's
/// structured query, normalizing resolutions/types and clamping sizes.
public enum DirectorySearchQueryConverter {

    public static func convert(_ intent: DirectorySearchIntent) -> DirectorySearchQuery {
        var query = DirectorySearchQuery()
        query.textTerms = (intent.textTerms ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        query.year = intent.year
        if let resolution = intent.resolution?.lowercased() {
            query.resolution = DirectoryFilenameNormalizer.canonicalResolution(for: resolution)
                ?? resolution
        }
        query.mediaType = mediaType(from: intent.mediaType)
        query.fileExtension = intent.fileExtension?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
        if query.fileExtension?.isEmpty == true { query.fileExtension = nil }
        if let gb = intent.minSizeGB, gb > 0 {
            query.minSizeBytes = Int64(gb * 1_073_741_824)
        }
        if let gb = intent.maxSizeGB, gb > 0 {
            query.maxSizeBytes = Int64(gb * 1_073_741_824)
        }
        switch intent.sort?.lowercased() {
        case "size", "sizedescending", "size_descending", "largest":
            query.sort = .sizeDescending
        case "date", "datedescending", "date_descending", "newest", "latest":
            query.sort = .dateDescending
        default:
            query.sort = .relevance
        }
        return query
    }

    private static func mediaType(from raw: String?) -> DirectoryItemType? {
        switch raw?.lowercased() {
        case "video", "movie", "movies", "film", "series", "show", "tv": return .video
        case "audio", "music", "song": return .audio
        case "image", "images", "picture", "photo": return .image
        case "archive", "zip", "compressed": return .archive
        case "document", "docs", "ebook", "book": return .document
        case "directory", "folder": return .directory
        default: return nil
        }
    }
}
