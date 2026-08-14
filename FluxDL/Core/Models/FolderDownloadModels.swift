import Foundation

// MARK: - FolderDownloadState

/// Aggregate state of a folder download group, derived from its child
/// downloads. A group is only `completed` when every required child has
/// finished; failed children surface as `partiallyCompleted`/`failed`.
public enum FolderDownloadState: String, Codable, CaseIterable, Sendable {
    case scanning = "Scanning"
    case queued = "Queued"
    case downloading = "Downloading"
    case paused = "Paused"
    case partiallyCompleted = "Partially Completed"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"

    public var title: String { rawValue }
}

// MARK: - FolderGroupChild

/// One planned child of a folder download group.
///
/// `taskID` is the `DownloadTaskModel.id` created by the existing
/// DownloadEngine; `relativePath` preserves the server-side hierarchy
/// (`"Extras/Trailer.mp4"`), and `expectedSize` keeps the scanned byte count
/// so aggregates are correct before a child task has started.
public struct FolderGroupChild: Identifiable, Codable, Equatable, Sendable {
    public let taskID: UUID
    public let url: URL
    public let filename: String
    public let relativePath: String
    public let expectedSize: Int64?

    public var id: UUID { taskID }

    public init(
        taskID: UUID,
        url: URL,
        filename: String,
        relativePath: String,
        expectedSize: Int64?
    ) {
        self.taskID = taskID
        self.url = url
        self.filename = filename
        self.relativePath = relativePath
        self.expectedSize = expectedSize
    }
}

// MARK: - DownloadFolderGroup

/// A logical folder download: metadata + planned children. The actual file
/// downloading is performed exclusively by the existing `DownloadEngine`
/// through the child tasks referenced by `children`.
public struct DownloadFolderGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let rootURL: URL
    public var destinationDirectoryPath: String
    public let createdAt: Date
    public var children: [FolderGroupChild]

    public init(
        id: UUID = UUID(),
        name: String,
        rootURL: URL,
        destinationDirectoryPath: String,
        createdAt: Date = Date(),
        children: [FolderGroupChild] = []
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.destinationDirectoryPath = destinationDirectoryPath
        self.createdAt = createdAt
        self.children = children
    }
}

// MARK: - FolderChildSnapshot

/// Live view of one child: its persisted plan + the current engine task.
public struct FolderChildSnapshot: Identifiable, Equatable {
    public let task: DownloadTaskModel
    public let relativePath: String
    public let expectedSize: Int64?

    public var id: UUID { task.id }

    /// Basename of the relative path — what the Downloads UI displays.
    public var displayName: String {
        let name = (relativePath as NSString).lastPathComponent
        return name.isEmpty ? task.filename : name
    }

    public var displayDirectory: String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "/" ? nil : parent
    }
}

// MARK: - FolderGroupSnapshot

/// Immutable, byte-weighted aggregate of a folder group computed from its
/// child downloads. Progress is `downloadedBytes / totalBytes`, never a
/// percentage average, so files of different sizes are weighted correctly.
public struct FolderGroupSnapshot: Identifiable, Equatable {

    public let group: DownloadFolderGroup
    public let children: [FolderChildSnapshot]
    public let state: FolderDownloadState

    public let totalBytes: Int64
    public let downloadedBytes: Int64
    public let speedBytesPerSec: Double
    public let remainingTimeSeconds: TimeInterval

    public let completedCount: Int
    public let failedCount: Int
    public let activeCount: Int
    public let pausedCount: Int
    public let cancelledCount: Int
    public let unknownSizeCount: Int

    public var id: UUID { group.id }

    public var fileCount: Int { children.count }

    public var progress: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0.0), 1.0)
    }

    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    public var formattedDownloadedSize: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    public var formattedSpeed: String {
        guard state == .downloading, speedBytesPerSec > 0 else { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSec), countStyle: .file) + "/s"
    }

    public var formattedETA: String {
        guard state == .downloading, remainingTimeSeconds > 0, !remainingTimeSeconds.isInfinite else { return "--:--" }
        let seconds = Int(remainingTimeSeconds) % 60
        let minutes = (Int(remainingTimeSeconds) / 60) % 60
        let hours   = Int(remainingTimeSeconds) / 3600
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// "8 files" / "8 files • 12.8 GB" — with an unknown-size caveat when
    /// metadata was missing during the scan.
    public var detailLine: String {
        var parts = ["\(fileCount) file\(fileCount == 1 ? "" : "s")"]
        if unknownSizeCount > 0 {
            parts.append("\(unknownSizeCount) size unknown")
        }
        return parts.joined(separator: " • ")
    }

    /// "7.4 GB / 12.8 GB" with speed + ETA appended while downloading.
    public var progressLine: String {
        var parts = ["\(formattedDownloadedSize) / \(formattedTotalSize)"]
        if state == .downloading || state == .queued {
            parts.append(formattedSpeed)
            parts.append("ETA \(formattedETA)")
        }
        return parts.joined(separator: "  •  ")
    }

    /// "4/8 completed" summary used by the Downloads UI.
    public var completionSummary: String {
        if completedCount == fileCount {
            return "\(fileCount) file\(fileCount == 1 ? "" : "s")"
        }
        var parts = ["\(completedCount)/\(fileCount) completed"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        return parts.joined(separator: ", ")
    }

    // MARK: init

    public init(group: DownloadFolderGroup, tasks: [DownloadTaskModel]) {
        self.group = group

        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var children: [FolderChildSnapshot] = []
        var total: Int64 = 0
        var downloaded: Int64 = 0
        var speed: Double = 0
        var completed = 0
        var failed = 0
        var downloading = 0
        var pending = 0
        var paused = 0
        var cancelled = 0
        var unknownSize = 0

        for child in group.children {
            guard let task = taskByID[child.taskID] else { continue }
            let expected = child.expectedSize ?? 0
            let taskTotal = max(task.totalBytes, task.downloadedBytes)
            let childTotal = max(expected, taskTotal)
            if childTotal > 0 {
                total += childTotal
            } else {
                unknownSize += 1
            }
            downloaded += task.downloadedBytes
            if task.status == .downloading {
                speed += max(task.speedBytesPerSec, 0)
            }
            switch task.status {
            case .completed: completed += 1
            case .failed: failed += 1
            case .downloading: downloading += 1
            case .pending: pending += 1
            case .paused: paused += 1
            case .cancelled: cancelled += 1
            }
            children.append(FolderChildSnapshot(
                task: task,
                relativePath: child.relativePath,
                expectedSize: child.expectedSize
            ))
        }

        self.children = children
        self.totalBytes = total
        self.downloadedBytes = downloaded
        self.speedBytesPerSec = speed
        self.remainingTimeSeconds = (speed > 0 && total > downloaded)
            ? Double(total - downloaded) / speed : 0
        self.completedCount = completed
        self.failedCount = failed
        self.activeCount = downloading + pending
        self.pausedCount = paused
        self.cancelledCount = cancelled
        self.unknownSizeCount = unknownSize
        self.state = FolderGroupSnapshot.deriveState(
            completed: completed,
            failed: failed,
            downloading: downloading,
            pending: pending,
            paused: paused,
            cancelled: cancelled,
            totalChildren: children.count
        )
    }

    /// Derives the group state from child status counts. A group is never
    /// completed while any child is unfinished.
    static func deriveState(
        completed: Int,
        failed: Int,
        downloading: Int,
        pending: Int,
        paused: Int,
        cancelled: Int,
        totalChildren: Int
    ) -> FolderDownloadState {
        guard totalChildren > 0 else { return .cancelled }
        if completed == totalChildren { return .completed }
        if downloading > 0 { return .downloading }
        if pending > 0 { return .queued }
        if paused > 0 { return .paused }
        if failed > 0 && completed > 0 { return .partiallyCompleted }
        if failed > 0 { return .failed }
        if cancelled > 0 { return .cancelled }
        return .cancelled
    }

    /// Downloads-tab filter semantics for folder groups:
    /// - All → always
    /// - Active → at least one child actively downloading
    /// - Waiting → at least one child queued
    /// - Paused → at least one child paused
    /// - Failed → at least one child failed
    /// - Completed → every child completed
    /// - Cancelled → every child cancelled
    public func matchesFilter(_ filter: DownloadStatusFilter) -> Bool {
        switch filter {
        case .all: return true
        case .active: return children.contains { $0.task.status == .downloading }
        case .waiting: return children.contains { $0.task.status == .pending }
        case .paused: return children.contains { $0.task.status == .paused }
        case .failed: return children.contains { $0.task.status == .failed }
        case .completed: return state == .completed
        case .cancelled: return state == .cancelled
        }
    }
}