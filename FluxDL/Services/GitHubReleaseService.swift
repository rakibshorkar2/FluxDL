import Foundation

// MARK: - Models

/// A downloadable file attached to a GitHub release.
public struct GitHubReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
    }
}

/// A GitHub release, decoded from the GitHub Releases API.
///
/// Only the fields FluxDL needs are decoded; GitHub may add extra fields
/// without breaking this model.
public struct GitHubRelease: Codable, Equatable, Sendable {
    public let tagName: String
    public let title: String
    public let releaseNotes: String
    public let releaseURL: URL
    public let publishedAt: Date?
    public let assets: [GitHubReleaseAsset]

    /// Normalized `major.minor.patch` version derived from the release tag.
    public var version: String {
        Self.deriveVersion(fromTag: tagName, fallbackTitle: title)
    }

    public var semanticVersion: SemanticVersion? {
        SemanticVersion(rawValue: version)
    }

    public var ipaAsset: GitHubReleaseAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".ipa") }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case title = "name"
        case releaseNotes = "body"
        case releaseURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        releaseURL = try container.decode(URL.self, forKey: .releaseURL)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        releaseNotes = (try? container.decodeIfPresent(String.self, forKey: .releaseNotes)) ?? ""
        publishedAt = Self.parseDate(try? container.decodeIfPresent(String.self, forKey: .publishedAt))
        assets = (try? container.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets)) ?? []
    }

    private static func deriveVersion(fromTag tag: String, fallbackTitle title: String) -> String {
        if let semantic = SemanticVersion(rawValue: tag) {
            return semantic.display
        }
        if let semantic = SemanticVersion(rawValue: title) {
            return semantic.display
        }
        return tag
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        return standard.date(from: raw)
    }
}

// MARK: - Errors

public enum UpdateCheckError: Error, Equatable, Sendable {
    case network
    case rateLimited
    case invalidResponse
    case invalidRelease
    case cancelled
}

// MARK: - GitHub Release Service

public protocol GitHubReleaseServiceProtocol: Sendable {
    func fetchLatestRelease(forceRefresh: Bool) async throws -> GitHubRelease
}

/// Fetches the latest FluxDL release from the public GitHub Releases API.
///
/// Successful responses are cached for a short period; errors are never
/// cached as an "up to date" result. A manual check passes `forceRefresh`
/// to bypass the cache.
public struct GitHubReleaseService: GitHubReleaseServiceProtocol {
    public static let repository = "rakibshorkar2/FluxDL"
    public static let cacheTTL: TimeInterval = 600

    private static let cacheReleaseKey = "fluxdl_update_cache_release"
    private static let cacheDateKey = "fluxdl_update_cache_date"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchLatestRelease(forceRefresh: Bool) async throws -> GitHubRelease {
        if !forceRefresh, let cached = Self.loadCachedRelease() {
            return cached
        }

        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FluxDL/\(AppVersionService().versionString)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw UpdateCheckError.cancelled }
            throw UpdateCheckError.network
        } catch is CancellationError {
            throw UpdateCheckError.cancelled
        } catch {
            throw UpdateCheckError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            throw UpdateCheckError.rateLimited
        case 404:
            throw UpdateCheckError.invalidRelease
        default:
            throw UpdateCheckError.invalidResponse
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }

        Self.storeCache(release)
        return release
    }

    // MARK: - Cache

    private static func loadCachedRelease() -> GitHubRelease? {
        guard let data = UserDefaults.standard.data(forKey: cacheReleaseKey),
              let date = UserDefaults.standard.object(forKey: cacheDateKey) as? Date,
              Date().timeIntervalSince(date) < cacheTTL,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else { return nil }
        return release
    }

    private static func storeCache(_ release: GitHubRelease) {
        if let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: cacheReleaseKey)
            UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        }
    }
}

// MARK: - Update Checker

public struct UpdateCheckResult: Equatable, Sendable {
    public let installedVersion: SemanticVersion
    public let latestRelease: GitHubRelease

    public var updateAvailable: Bool {
        guard let latest = latestRelease.semanticVersion else { return false }
        return latest > installedVersion
    }
}

public protocol UpdateCheckerProtocol: Sendable {
    func checkForUpdates(forceRefresh: Bool) async throws -> UpdateCheckResult
}

/// Combines the installed app version with the latest GitHub release and
/// decides whether an update is available using semantic versioning.
public struct UpdateChecker: UpdateCheckerProtocol {
    private let releaseService: GitHubReleaseServiceProtocol
    private let versionService: AppVersionServiceProtocol

    public init(
        releaseService: GitHubReleaseServiceProtocol = GitHubReleaseService(),
        versionService: AppVersionServiceProtocol = AppVersionService()
    ) {
        self.releaseService = releaseService
        self.versionService = versionService
    }

    public func checkForUpdates(forceRefresh: Bool) async throws -> UpdateCheckResult {
        let release = try await releaseService.fetchLatestRelease(forceRefresh: forceRefresh)
        guard let installed = versionService.semanticVersion else {
            throw UpdateCheckError.invalidResponse
        }
        guard release.semanticVersion != nil else {
            throw UpdateCheckError.invalidRelease
        }
        return UpdateCheckResult(installedVersion: installed, latestRelease: release)
    }
}

// MARK: - Release Notes Sanitization

public enum ReleaseNotesSanitizer {
    /// Converts GitHub-flavored markdown release notes into plain, readable
    /// text for alerts. Never rendered as HTML or markdown.
    public static func plainText(_ body: String, maxLength: Int = 500) -> String {
        let lines = body
            .components(separatedBy: .newlines)
            .map { line in
                var line = line.trimmingCharacters(in: .whitespaces)
                line = line.replacingOccurrences(of: #"^[-*+]\s+"#, with: "• ", options: .regularExpression)
                line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                line = line.replacingOccurrences(of: "`", with: "")
                line = line.replacingOccurrences(of: "**", with: "")
                line = line.replacingOccurrences(of: "*", with: "")
                return line
            }
        let joined = lines
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if joined.count <= maxLength { return joined }
        return String(joined.prefix(maxLength)) + "…"
    }
}
