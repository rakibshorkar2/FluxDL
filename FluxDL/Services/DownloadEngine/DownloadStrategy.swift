import Foundation

// MARK: - Strategy

/// The download strategy the engine is currently using (or should use) for a
/// task. Persisted on the task so resumed/relaunched downloads follow the
/// same plan without re-probing.
public enum DownloadStrategy: String, Codable, Equatable, Sendable {
    /// Single-connection plain download (existing reliable path).
    case normal = "Normal"
    /// Multi-connection byte-range download.
    case segmented = "Segmented"
    /// Resume-aware single download (range-validated continuation).
    case resumable = "Resumable"
    /// Downloading through a mirror.
    case mirror = "Mirror"
    /// Currently between retry attempts.
    case retry = "Retry"
    /// Waiting for the network to become available.
    case waitingForNetwork = "Waiting for Network"
    /// Waiting for free disk space.
    case waitingForStorage = "Waiting for Storage"
    /// Waiting for its turn in the queue.
    case waitingForSchedule = "Waiting for Schedule"

    public var isIdle: Bool {
        self == .waitingForNetwork || self == .waitingForStorage || self == .waitingForSchedule
    }
}

// MARK: - Probe result

/// Everything learned about a URL before (or while) downloading it.
public struct DownloadProbeResult: Sendable, Equatable {
    public let httpStatus: Int?
    public let finalURL: URL?
    public let contentLength: Int64?
    public let mimeType: String?
    public let filename: String?
    public let contentDisposition: String?
    public let acceptsRanges: Bool
    public let etag: String?
    public let lastModified: String?
    public let serverName: String?
    public let redirectCount: Int
    public let httpVersion: String?
    public let requiresAuthentication: Bool
    /// Estimated time-to-live risk for signed/expiring URLs (informational).
    public let expirationRisk: DownloadExpirationRisk
    public let headers: [String: String]
    public let probedAt: Date

    public init(
        httpStatus: Int? = nil,
        finalURL: URL? = nil,
        contentLength: Int64? = nil,
        mimeType: String? = nil,
        filename: String? = nil,
        contentDisposition: String? = nil,
        acceptsRanges: Bool = false,
        etag: String? = nil,
        lastModified: String? = nil,
        serverName: String? = nil,
        redirectCount: Int = 0,
        httpVersion: String? = nil,
        requiresAuthentication: Bool = false,
        expirationRisk: DownloadExpirationRisk = .unknown,
        headers: [String: String] = [:],
        probedAt: Date = Date()
    ) {
        self.httpStatus = httpStatus
        self.finalURL = finalURL
        self.contentLength = contentLength
        self.mimeType = mimeType
        self.filename = filename
        self.contentDisposition = contentDisposition
        self.acceptsRanges = acceptsRanges
        self.etag = etag
        self.lastModified = lastModified
        self.serverName = serverName
        self.redirectCount = redirectCount
        self.httpVersion = httpVersion
        self.requiresAuthentication = requiresAuthentication
        self.expirationRisk = expirationRisk
        self.headers = headers
        self.probedAt = probedAt
    }

    public var isHTTP2: Bool { (httpVersion ?? "").contains("2") }
}

// MARK: - Expiration risk

/// Informational classification of a URL's expiry likelihood. Never claimed
/// as certainty from query parameters alone.
public enum DownloadExpirationRisk: String, Sendable, Equatable {
    case unknown = "Unknown"
    case likelyExpiring = "May Expire"
    case likelyExpired = "Likely Expired"
    case stable = "Stable"

    /// Signature/token indicators commonly found on temporary (signed) URLs.
    /// Deliberately conservative: presence does not prove expiry.
    public static func from(url: URL) -> DownloadExpirationRisk {
        let query = url.query ?? ""
        let indicators = [
            "X-Amz-Signature", "X-Amz-Credential", "X-Amz-Expires", "AWSAccessKeyId",
            "X-Goog-Signature", "X-Goog-Algorithm", "X-Goog-Credential", "X-Goog-Date", "X-Goog-Expires",
            "GoogleAccessId", "Expires=", "Signature=", "sig=", "sp=", "st=", "se=", "sv=", "spr="
        ]
        let upper = query.uppercased()
        for indicator in indicators where upper.contains(indicator.uppercased()) {
            return .likelyExpiring
        }
        return .unknown
    }
}

// MARK: - Strategy selection

/// Deterministic, network-free strategy selection. The engine probes a URL,
/// feeds the result here, and receives a recommended strategy plus the
/// starting connection count.
public enum DownloadStrategyEngine {

    public struct Recommendation: Sendable, Equatable {
        public let strategy: DownloadStrategy
        public let connectionCount: Int
        public let reason: String
    }

    /// Minimum file size before segmentation is considered at all.
    public static let minimumSegmentableBytes: Int64 = 50 * 1024 * 1024

    /// Whether a URL is eligible for segmented downloading at all.
    public static func isSegmentableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Full strategy recommendation.
    public static func recommend(
        probe: DownloadProbeResult?,
        url: URL,
        existingBytes: Int64,
        segmentedEnabled: Bool,
        proxiedRouteActive: Bool
    ) -> Recommendation {
        guard let probe else {
            // No metadata: use the reliable normal path; do not gamble on
            // byte ranges we cannot validate.
            return Recommendation(strategy: .normal, connectionCount: 1, reason: "No metadata available")
        }
        guard probe.httpStatus == nil || (200...299).contains(probe.httpStatus!) else {
            if let status = probe.httpStatus, status == 401 || status == 403 {
                return Recommendation(strategy: .retry, connectionCount: 1, reason: "HTTP \(status) — URL may require authentication or have expired")
            }
            return Recommendation(strategy: .retry, connectionCount: 1, reason: "HTTP \(probe.httpStatus!)")
        }

        // Existing partial data: resume-aware normal path unless we can prove
        // safe range continuation (matches the intelligent resume rules).
        if existingBytes > 0 {
            let canContinueRange = probe.acceptsRanges && probe.contentLength != nil
            let strategy: DownloadStrategy = canContinueRange ? .resumable : .normal
            return Recommendation(strategy: strategy, connectionCount: 1, reason: "Partial data present — range-validated continuation")
        }

        guard segmentedEnabled, !proxiedRouteActive, probe.acceptsRanges,
              let length = probe.contentLength, length >= minimumSegmentableBytes,
              isSegmentableScheme(probe.finalURL ?? url) else {
            let count = probe.contentLength ?? 0 >= minimumSegmentableBytes ? DownloadSegmentMap.initialConnectionCount(totalBytes: probe.contentLength ?? 0) : 1
            let strategy: DownloadStrategy = probe.acceptsRanges ? .resumable : .normal
            return Recommendation(strategy: strategy, connectionCount: min(count, 1), reason: "Segmentation not eligible — using \(strategy.rawValue)")
        }

        let connections = DownloadSegmentMap.initialConnectionCount(totalBytes: length)
        return Recommendation(
            strategy: .segmented,
            connectionCount: connections,
            reason: "Range supported, \(ByteCountFormatter.string(fromByteCount: length, countStyle: .file)) — segmented"
        )
    }
}
