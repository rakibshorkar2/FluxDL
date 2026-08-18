import Foundation

// MARK: - DownloadStatus

public enum DownloadStatus: String, Codable, CaseIterable {
    case pending    = "Pending"
    case downloading = "Downloading"
    case paused     = "Paused"
    case completed  = "Completed"
    case failed     = "Failed"
    case cancelled  = "Cancelled"
}

// MARK: - DownloadPriority

public enum DownloadPriority: Int, Codable, CaseIterable, Comparable, CustomStringConvertible {
    case low    = 0
    case normal = 1
    case high   = 2

    public var description: String {
        switch self {
        case .high:   return "High"
        case .normal: return "Normal"
        case .low:    return "Low"
        }
    }

    public static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - RetryRecord

/// Records a single retry attempt for diagnostics purposes.
public struct RetryRecord: Codable, Equatable {
    public let date: Date
    public let errorMessage: String?
    public let httpStatus: Int?

    public init(date: Date = Date(), errorMessage: String? = nil, httpStatus: Int? = nil) {
        self.date = date
        self.errorMessage = errorMessage
        self.httpStatus = httpStatus
    }
}

// MARK: - DownloadTaskModel

public struct DownloadTaskModel: Identifiable, Codable, Equatable {

    // ── Core identity ────────────────────────────────────────────────────────
    public let id: UUID
    /// Primary (original) download URL.
    public var url: URL
    public var filename: String
    public var destinationPath: String?
    public var status: DownloadStatus
    public var priority: DownloadPriority

    // ── Queue / retry ────────────────────────────────────────────────────────
    public var retryCount: Int
    public var maxRetries: Int
    public var queuePosition: Int

    // ── Progress ─────────────────────────────────────────────────────────────
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var speedBytesPerSec: Double
    public var averageSpeedBytesPerSec: Double
    public var remainingTimeSeconds: TimeInterval

    // ── Session ──────────────────────────────────────────────────────────────
    public var resumeData: Data?
    public var errorMessage: String?
    public var sessionTaskIdentifier: Int?

    // ── Timestamps ───────────────────────────────────────────────────────────
    public let createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?

    // ── Mirror support ───────────────────────────────────────────────────────
    /// Additional mirror URLs (index 0 is the first mirror, separate from `url`).
    public var mirrors: [URL]
    /// 0 = primary `url`; >0 = mirrors[currentMirrorIndex - 1].
    public var currentMirrorIndex: Int
    /// How many times the engine has auto-switched mirrors.
    public var mirrorSwitchCount: Int

    // ── Server / HTTP metadata ───────────────────────────────────────────────
    public var lastHTTPStatusCode: Int?
    /// Whether the server advertised `Accept-Ranges: bytes`.
    public var acceptsRanges: Bool
    public var etag: String?
    public var lastModified: String?
    public var mimeType: String?
    public var serverName: String?
    public var redirectCount: Int
    /// Safe subset of response headers (populated on completion / error).
    public var responseHeaders: [String: String]?

    // ── Checksums ────────────────────────────────────────────────────────────
    public var sha256Hash: String?
    public var md5Hash: String?

    // ── Diagnostics ──────────────────────────────────────────────────────────
    public var retryHistory: [RetryRecord]

    // ── Tags (future) ────────────────────────────────────────────────────────
    public var tags: [String]

    // ── Folder download group membership (optional) ───────────────────────────
    /// When set, this task is a child of the folder download group with this
    /// ID. `nil` for ordinary standalone downloads.
    public var folderGroupID: UUID?
    /// Path of this child relative to the folder's destination directory
    /// (e.g. `"Extras/Trailer.mp4"`). `nil` for standalone downloads.
    public var relativePath: String?
    /// Absolute path of the folder's destination directory. Folder children
    /// are saved under this directory (preserving `relativePath`), instead of
    /// the smart-routing root. `nil` for standalone downloads.
    public var destinationDirectoryPath: String?

    // ── Smart download engine (additive; nil/default = legacy behavior) ──────
    /// The strategy the engine is using for this task (normal/segmented/…).
    /// `nil` means the legacy single-connection path.
    public var activeStrategy: DownloadStrategy?
    /// Byte-range segments for segmented downloads; `nil` for non-segmented.
    public var segmentStates: [DownloadSegment]?
    /// Latest health classification (throttled UI updates).
    public var healthState: DownloadHealthState?
    /// Number of concurrent connections in use (0 = single connection).
    public var activeConnections: Int
    /// Set when the retry/mirror machinery gave up and the user should act.
    public var needsAttention: Bool

    // MARK: Computed helpers

    public var progress: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0.0), 1.0)
    }

    public var formattedSpeed: String {
        guard status == .downloading, speedBytesPerSec > 0 else { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSec), countStyle: .file) + "/s"
    }

    public var formattedAverageSpeed: String {
        guard averageSpeedBytesPerSec > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(averageSpeedBytesPerSec), countStyle: .file) + "/s"
    }

    public var formattedETA: String {
        guard status == .downloading, remainingTimeSeconds > 0, !remainingTimeSeconds.isInfinite else { return "--:--" }
        let seconds = Int(remainingTimeSeconds) % 60
        let minutes = (Int(remainingTimeSeconds) / 60) % 60
        let hours   = Int(remainingTimeSeconds) / 3600
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    public var formattedDownloadedSize: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    public var formattedTotalSize: String {
        let bytes = totalBytes > 0 ? totalBytes : (status == .completed ? downloadedBytes : 0)
        guard bytes > 0 else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The URL currently being used (primary or mirror).
    public var activeURL: URL {
        if currentMirrorIndex == 0 { return url }
        let mirrorIdx = currentMirrorIndex - 1
        guard mirrorIdx < mirrors.count else { return url }
        return mirrors[mirrorIdx]
    }

    // MARK: init

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String? = nil,
        destinationPath: String? = nil,
        status: DownloadStatus = .pending,
        priority: DownloadPriority = .normal,
        retryCount: Int = 0,
        maxRetries: Int = 3,
        queuePosition: Int = 0,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        speedBytesPerSec: Double = 0.0,
        averageSpeedBytesPerSec: Double = 0.0,
        remainingTimeSeconds: TimeInterval = 0,
        resumeData: Data? = nil,
        errorMessage: String? = nil,
        sessionTaskIdentifier: Int? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        mirrors: [URL] = [],
        currentMirrorIndex: Int = 0,
        mirrorSwitchCount: Int = 0,
        lastHTTPStatusCode: Int? = nil,
        acceptsRanges: Bool = false,
        etag: String? = nil,
        lastModified: String? = nil,
        mimeType: String? = nil,
        serverName: String? = nil,
        redirectCount: Int = 0,
        responseHeaders: [String: String]? = nil,
        sha256Hash: String? = nil,
        md5Hash: String? = nil,
        retryHistory: [RetryRecord] = [],
        tags: [String] = [],
        folderGroupID: UUID? = nil,
        relativePath: String? = nil,
        destinationDirectoryPath: String? = nil,
        activeStrategy: DownloadStrategy? = nil,
        segmentStates: [DownloadSegment]? = nil,
        healthState: DownloadHealthState? = nil,
        activeConnections: Int = 0,
        needsAttention: Bool = false
    ) {
        self.id                       = id
        self.url                      = url
        self.filename                 = filename ?? URLFilenameExtractor.extractFilename(from: url)
        self.destinationPath          = destinationPath
        self.status                   = status
        self.priority                 = priority
        self.retryCount               = retryCount
        self.maxRetries               = maxRetries
        self.queuePosition            = queuePosition
        self.totalBytes               = totalBytes
        self.downloadedBytes          = downloadedBytes
        self.speedBytesPerSec         = speedBytesPerSec
        self.averageSpeedBytesPerSec  = averageSpeedBytesPerSec
        self.remainingTimeSeconds     = remainingTimeSeconds
        self.resumeData               = resumeData
        self.errorMessage             = errorMessage
        self.sessionTaskIdentifier    = sessionTaskIdentifier
        self.createdAt                = createdAt
        self.startedAt                = startedAt
        self.completedAt              = completedAt
        self.mirrors                  = mirrors
        self.currentMirrorIndex       = currentMirrorIndex
        self.mirrorSwitchCount        = mirrorSwitchCount
        self.lastHTTPStatusCode       = lastHTTPStatusCode
        self.acceptsRanges            = acceptsRanges
        self.etag                     = etag
        self.lastModified             = lastModified
        self.mimeType                 = mimeType
        self.serverName               = serverName
        self.redirectCount            = redirectCount
        self.responseHeaders          = responseHeaders
        self.sha256Hash               = sha256Hash
        self.md5Hash                  = md5Hash
        self.retryHistory             = retryHistory
        self.tags                     = tags
        self.folderGroupID            = folderGroupID
        self.relativePath             = relativePath
        self.destinationDirectoryPath = destinationDirectoryPath
        self.activeStrategy           = activeStrategy
        self.segmentStates            = segmentStates
        self.healthState              = healthState
        self.activeConnections        = activeConnections
        self.needsAttention           = needsAttention
    }

    // MARK: Codable — backward-compatible decode (old JSON missing new keys)

    private enum CodingKeys: String, CodingKey {
        case id, url, filename, destinationPath, status, priority
        case retryCount, maxRetries, queuePosition
        case totalBytes, downloadedBytes, speedBytesPerSec, averageSpeedBytesPerSec, remainingTimeSeconds
        case resumeData, errorMessage, sessionTaskIdentifier
        case createdAt, startedAt, completedAt
        case mirrors, currentMirrorIndex, mirrorSwitchCount
        case lastHTTPStatusCode, acceptsRanges, etag, lastModified
        case mimeType, serverName, redirectCount, responseHeaders
        case sha256Hash, md5Hash
        case retryHistory, tags
        case folderGroupID, relativePath, destinationDirectoryPath
        case activeStrategy, segmentStates, healthState, activeConnections, needsAttention
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id                      = try c.decode(UUID.self,           forKey: .id)
        url                     = try c.decode(URL.self,            forKey: .url)
        filename                = try c.decode(String.self,         forKey: .filename)
        destinationPath         = try c.decodeIfPresent(String.self, forKey: .destinationPath)
        status                  = try c.decode(DownloadStatus.self,  forKey: .status)
        priority                = try c.decodeIfPresent(DownloadPriority.self, forKey: .priority) ?? .normal
        retryCount              = try c.decodeIfPresent(Int.self,    forKey: .retryCount)    ?? 0
        maxRetries              = try c.decodeIfPresent(Int.self,    forKey: .maxRetries)    ?? 3
        queuePosition           = try c.decodeIfPresent(Int.self,    forKey: .queuePosition) ?? 0
        totalBytes              = try c.decodeIfPresent(Int64.self,  forKey: .totalBytes)    ?? 0
        downloadedBytes         = try c.decodeIfPresent(Int64.self,  forKey: .downloadedBytes) ?? 0
        speedBytesPerSec        = try c.decodeIfPresent(Double.self, forKey: .speedBytesPerSec) ?? 0
        averageSpeedBytesPerSec = try c.decodeIfPresent(Double.self, forKey: .averageSpeedBytesPerSec) ?? 0
        remainingTimeSeconds    = try c.decodeIfPresent(TimeInterval.self, forKey: .remainingTimeSeconds) ?? 0
        resumeData              = try c.decodeIfPresent(Data.self,   forKey: .resumeData)
        errorMessage            = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        sessionTaskIdentifier   = try c.decodeIfPresent(Int.self,    forKey: .sessionTaskIdentifier)
        createdAt               = try c.decodeIfPresent(Date.self,   forKey: .createdAt) ?? Date()
        startedAt               = try c.decodeIfPresent(Date.self,   forKey: .startedAt)
        completedAt             = try c.decodeIfPresent(Date.self,   forKey: .completedAt)
        mirrors                 = try c.decodeIfPresent([URL].self,  forKey: .mirrors)  ?? []
        currentMirrorIndex      = try c.decodeIfPresent(Int.self,    forKey: .currentMirrorIndex) ?? 0
        mirrorSwitchCount       = try c.decodeIfPresent(Int.self,    forKey: .mirrorSwitchCount)  ?? 0
        lastHTTPStatusCode      = try c.decodeIfPresent(Int.self,    forKey: .lastHTTPStatusCode)
        acceptsRanges           = try c.decodeIfPresent(Bool.self,   forKey: .acceptsRanges) ?? false
        etag                    = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified            = try c.decodeIfPresent(String.self, forKey: .lastModified)
        mimeType                = try c.decodeIfPresent(String.self, forKey: .mimeType)
        serverName              = try c.decodeIfPresent(String.self, forKey: .serverName)
        redirectCount           = try c.decodeIfPresent(Int.self,    forKey: .redirectCount) ?? 0
        responseHeaders         = try c.decodeIfPresent([String: String].self, forKey: .responseHeaders)
        sha256Hash              = try c.decodeIfPresent(String.self, forKey: .sha256Hash)
        md5Hash                 = try c.decodeIfPresent(String.self, forKey: .md5Hash)
        retryHistory            = try c.decodeIfPresent([RetryRecord].self, forKey: .retryHistory) ?? []
        tags                    = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        folderGroupID           = try c.decodeIfPresent(UUID.self, forKey: .folderGroupID)
        relativePath            = try c.decodeIfPresent(String.self, forKey: .relativePath)
        destinationDirectoryPath = try c.decodeIfPresent(String.self, forKey: .destinationDirectoryPath)
        activeStrategy          = try c.decodeIfPresent(DownloadStrategy.self, forKey: .activeStrategy)
        segmentStates           = try c.decodeIfPresent([DownloadSegment].self, forKey: .segmentStates)
        healthState             = try c.decodeIfPresent(DownloadHealthState.self, forKey: .healthState)
        activeConnections       = try c.decodeIfPresent(Int.self, forKey: .activeConnections) ?? 0
        needsAttention          = try c.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
    }
}
