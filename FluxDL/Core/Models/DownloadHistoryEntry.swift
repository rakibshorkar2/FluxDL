import Foundation

// MARK: - DownloadHistoryChange

/// Describes how a history record changed during a task sync.
public enum DownloadHistoryChange {
    case none
    /// Byte-progress only (throttled persistence).
    case minor
    /// Status / URL / filename / timestamps / metadata (persist immediately).
    case critical
}

// MARK: - DownloadHistoryEntry

/// Persistent record of a download — independent from the visible active
/// Downloads list. Deleting a download never removes its history record.
public struct DownloadHistoryEntry: Identifiable, Codable, Equatable {

    // ── Identity ────────────────────────────────────────────────────────────
    /// Stable UUID shared with the originating `DownloadTaskModel`.
    public let id: UUID
    public var filename: String
    /// The original download link — preserved forever, even if the task's URL
    /// is later updated. This is what "Copy Link" always restores.
    public let originalURL: URL
    /// Final / effective URL if the task was retried with a new link.
    public var effectiveURL: URL?

    // ── Timeline ─────────────────────────────────────────────────────────────
    public var dateAdded: Date
    public var completedAt: Date?

    // ── State / size / type ──────────────────────────────────────────────────
    public var status: DownloadStatus
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var mimeType: String?
    public var errorMessage: String?

    // MARK: Init

    public init(task: DownloadTaskModel) {
        self.id             = task.id
        self.filename       = task.filename
        self.originalURL    = task.url
        self.effectiveURL   = task.url
        self.dateAdded      = task.createdAt
        self.completedAt    = task.completedAt
        self.status         = task.status
        self.totalBytes     = task.totalBytes
        self.downloadedBytes = task.downloadedBytes
        self.mimeType       = task.mimeType
        self.errorMessage   = task.errorMessage
    }

    public init(
        id: UUID,
        filename: String,
        originalURL: URL,
        effectiveURL: URL?,
        dateAdded: Date,
        completedAt: Date?,
        status: DownloadStatus,
        totalBytes: Int64,
        downloadedBytes: Int64,
        mimeType: String?,
        errorMessage: String?
    ) {
        self.id              = id
        self.filename        = filename
        self.originalURL     = originalURL
        self.effectiveURL    = effectiveURL
        self.dateAdded       = dateAdded
        self.completedAt     = completedAt
        self.status          = status
        self.totalBytes      = totalBytes
        self.downloadedBytes = downloadedBytes
        self.mimeType        = mimeType
        self.errorMessage    = errorMessage
    }

    // MARK: Sync

    /// Applies the current task state onto this record. Never mutates
    /// `id` or `originalURL` so the original link is always recoverable.
    @discardableResult
    public mutating func update(from task: DownloadTaskModel) -> DownloadHistoryChange {
        var change: DownloadHistoryChange = .none

        if filename != task.filename {
            filename = task.filename
            change = .critical
        }
        if effectiveURL != task.url {
            effectiveURL = task.url
            change = .critical
        }
        if completedAt != task.completedAt {
            completedAt = task.completedAt
            change = .critical
        }
        if status != task.status {
            status = task.status
            change = .critical
        }
        if mimeType != task.mimeType {
            mimeType = task.mimeType
            change = .critical
        }
        if errorMessage != task.errorMessage {
            errorMessage = task.errorMessage
            change = .critical
        }
        if totalBytes != task.totalBytes {
            totalBytes = task.totalBytes
            if change == .none { change = .minor }
        }
        if downloadedBytes != task.downloadedBytes {
            downloadedBytes = task.downloadedBytes
            if change == .none { change = .minor }
        }

        return change
    }

    // MARK: Display helpers

    public var displayHost: String {
        originalURL.host ?? originalURL.absoluteString
    }

    public var formattedTotalSize: String {
        let bytes = totalBytes > 0 ? totalBytes : downloadedBytes
        guard bytes > 0 else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
