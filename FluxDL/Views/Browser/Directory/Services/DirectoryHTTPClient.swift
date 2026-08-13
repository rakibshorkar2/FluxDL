import Foundation
import Combine

/// Errors surfaced by the Directory Mode network stack.
public enum DirectoryHTTPError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme(String)
    case timeout
    case connectionFailed
    case proxyUnavailable
    case httpStatus(Int)
    case malformedResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL. Check the address and try again."
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme \"\(scheme)\". Only HTTP and HTTPS are supported."
        case .timeout:
            return "Connection timed out. Check your network or proxy."
        case .connectionFailed:
            return "Connection failed. The server may be unreachable."
        case .proxyUnavailable:
            return "The active proxy could not be applied. Directory browsing stays blocked until the proxy is ready — it will not fall back to a direct connection."
        case .httpStatus(let code):
            return httpStatusMessage(code)
        case .malformedResponse:
            return "The server returned a malformed response."
        case .cancelled:
            return "Request cancelled."
        }
    }

    private func httpStatusMessage(_ code: Int) -> String {
        switch code {
        case 401: return "Authentication required (HTTP 401). The server rejected the request without credentials."
        case 403: return "Access denied (HTTP 403). The server refuses to list this directory."
        case 404: return "Not found (HTTP 404). The directory does not exist on the server."
        case 429: return "Too many requests (HTTP 429). Try again in a moment."
        case 500..<600: return "Server error (HTTP \(code)). The server failed to respond correctly."
        default: return "Request failed (HTTP \(code))."
        }
    }
}

/// Minimal result of one directory fetch.
public struct DirectoryFetchResult: Sendable {
    public let data: Data
    public let finalURL: URL
    public let contentType: String?
    public let mimeType: String?

    public init(data: Data, finalURL: URL, contentType: String?, mimeType: String?) {
        self.data = data
        self.finalURL = finalURL
        self.contentType = contentType
        self.mimeType = mimeType
    }
}

/// Fetches directory pages through FluxDL's existing proxy architecture.
///
/// Every request builds its session from `BrowserProxySession.shared
/// .sessionConfiguration()` — the same policy as the Web Browser's app-level
/// traffic. When the browser proxy route is enabled but cannot be applied
/// (`sessionConfiguration()` returns nil), fetches FAIL with
/// `proxyUnavailable`; there is never a silent fallback to direct networking.
///
/// Sessions are invalidated whenever `proxyDidChange` fires so a stale
/// session is never retained across profile switches.
@MainActor
public final class DirectoryHTTPClient: ObservableObject {

    public static let shared = DirectoryHTTPClient()

    private let proxySession = BrowserProxySession.shared
    private var cancellables = Set<AnyCancellable>()

    public private(set) var proxyFingerprint: String?
    public private(set) var isProxyActive: Bool = false
    public private(set) var proxyLabel: String?

    public init() {
        proxySession.proxyDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshProxyState() }
            .store(in: &cancellables)
        refreshProxyState()
    }

    private func refreshProxyState() {
        isProxyActive = proxySession.isProxyActive
        proxyLabel = proxySession.proxyLabel
        proxyFingerprint = proxySession.activeConfiguration?.fingerprint
    }

    /// Fetches a directory page. Throws `DirectoryHTTPError` on failure.
    /// Returns the final (redirect-followed) URL so breadcrumbs stay correct.
    public func fetch(url: URL) async throws -> DirectoryFetchResult {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw DirectoryHTTPError.unsupportedScheme(url.scheme ?? "")
        }
        guard let configuration = proxySession.sessionConfiguration() else {
            throw DirectoryHTTPError.proxyUnavailable
        }
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("FluxDL/1.0 (directory mode)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DirectoryHTTPError.malformedResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DirectoryHTTPError.httpStatus(http.statusCode)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            let mimeType = contentType?.split(separator: ";").first.map(String.init)
            return DirectoryFetchResult(
                data: data,
                finalURL: http.url ?? url,
                contentType: contentType,
                mimeType: mimeType
            )
        } catch is CancellationError {
            throw DirectoryHTTPError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw DirectoryHTTPError.timeout
            case .cancelled:
                throw DirectoryHTTPError.cancelled
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .cannotFindHost, .internationalRoamingOff, .dataNotAllowed:
                throw DirectoryHTTPError.connectionFailed
            default:
                throw DirectoryHTTPError.connectionFailed
            }
        }
    }

    /// Whether a URL must bypass the proxy (localhost). Mirrors
    /// `BrowserProxySession.shouldBypassProxy`.
    public func shouldBypassProxy(for url: URL) -> Bool {
        proxySession.shouldBypassProxy(for: url)
    }
}