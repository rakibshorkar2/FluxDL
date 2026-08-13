import Foundation
import LibTorrent

// MARK: - AddTorrentOptions

/// Per-torrent settings applied when a new torrent is added.
public struct AddTorrentOptions: Equatable {
    public var stopSeeding: Bool = false
    public var sequentialDownload: Bool = false
    public var firstLastPiecePriority: Bool = false
    /// Bytes per second; -1 means unlimited, 0 means paused transfers.
    public var downloadLimit: Int64 = -1
    public var uploadLimit: Int64 = -1

    public init() {}
}

// MARK: - TorrentFileItem

public struct TorrentFileItem: Identifiable, Equatable {
    public let index: Int
    public let name: String
    public let size: Int64
    public let downloaded: Int64
    public let priority: FileEntry.Priority

    public var id: Int { index }

    /// Progress of this single file, clamped to 0...1.
    public var progress: Double {
        guard size > 0 else { return 0 }
        return min(1, max(0, Double(downloaded) / Double(size)))
    }
}

// MARK: - TorrentTrackerItem

public struct TorrentTrackerItem: Identifiable, Equatable {
    public let url: String
    public let state: TorrentTracker.State
    public let seeds: Int
    public let peers: Int
    public let leeches: Int
    public let downloaded: Int
    /// When the engine schedules the next announce, if it can be reported.
    public let nextAnnounceTime: Date?
    public let message: String?

    public var id: String { url }

    /// Tracker swarm statistics are -1 until the engine has scraped them.
    public var hasSwarmStats: Bool {
        seeds >= 0 && peers >= 0 && leeches >= 0
    }
}

// MARK: - TorrentTaskModel

/// One immutable snapshot of a torrent in the session.
///
/// `id` is the info-hash hex string and the stable identity of every torrent.
/// Never identify a torrent by its position in any array.
public struct TorrentTaskModel: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var state: TorrentHandle.State
    public var progress: Double
    public var downloadRate: Int64
    public var uploadRate: Int64
    /// Estimated seconds until the download finishes; nil when not downloading or rate is zero.
    public var eta: TimeInterval?
    /// Per-torrent speed limits in bytes/sec; -1 means unlimited.
    public var downloadLimit: Int64
    public var uploadLimit: Int64
    public var total: Int64
    public var totalDone: Int64
    public var totalDownload: Int64
    public var totalUpload: Int64
    public var seeds: Int
    public var peers: Int
    public var leechers: Int
    public var totalSeeds: Int
    public var totalPeers: Int
    public var totalLeechers: Int
    public var files: [TorrentFileItem]
    public var trackers: [TorrentTrackerItem]
    public var magnetLink: String?
    public var comment: String?
    public var creator: String?
    /// Creation date written into the torrent metadata; nil when the torrent
    /// file does not carry one. Never epoch 1970.
    public var creationDate: Date?
    /// The date the engine recorded the torrent as added (restored from resume data).
    public var addedDate: Date?
    /// The stable, persisted timestamp representing when this torrent arrived
    /// in FluxDL. Assigned once, never reset across restarts.
    public var createdAt: Date
    /// On-disk location of the torrent's content.
    public var downloadPath: String?
    public var pieceLength: Int
    public var pieceCount: Int
    /// True when the engine is downloading but makes no progress for a sustained
    /// period. Computed by the service, not reported by libtorrent directly.
    public var isStalled: Bool
    public var isPaused: Bool
    public var isSeed: Bool
    public var isFinished: Bool
    public var stopSeeding: Bool
    public var isSequential: Bool
    public var isFirstLastPiecePriority: Bool

    // MARK: - Authoritative derived values

    /// Progress clamped to 0...1. The engine value is authoritative but must
    /// never render as NaN, infinity or out-of-range.
    public var clampedProgress: Double {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    /// Remainder to download; never negative.
    public var remainingBytes: Int64 {
        max(0, total - totalDone)
    }

    /// Whole percent for display with proper rounding (0...100).
    public var displayPercentage: Int {
        guard total > 0 else { return 0 }
        guard !isFinished else { return 100 }
        return Int((clampedProgress * 100).rounded())
    }

    /// Upload / download ratio; nil until something has been downloaded.
    public var ratio: Double? {
        guard totalDownload > 0 else { return nil }
        return Double(totalUpload) / Double(totalDownload)
    }

    /// Average download speed since the torrent was added, when derivable.
    public var averageDownloadRate: Int64? {
        guard let added = addedDate else { return nil }
        let elapsed = Date().timeIntervalSince(added)
        guard elapsed > 0, totalDownload > 0 else { return nil }
        return Int64(Double(totalDownload) / elapsed)
    }

    /// Average upload speed since the torrent was added, when derivable.
    public var averageUploadRate: Int64? {
        guard let added = addedDate else { return nil }
        let elapsed = Date().timeIntervalSince(added)
        guard elapsed > 0, totalUpload > 0 else { return nil }
        return Int64(Double(totalUpload) / elapsed)
    }

    /// Is this torrent actively transferring (downloading or seeding)?
    public var isActive: Bool {
        !isPaused && state != .storageError
    }

    /// Human status for the UI. Stalled is an app-level presentation of a real
    /// engine condition (downloading with zero throughput), everything else is
    /// the authoritative engine state.
    public var statusTitle: String {
        if isStalled { return "Stalled" }
        switch state {
        case .storageError: return "Storage Error"
        default: break
        }
        return state.displayTitle
    }

    // MARK: - Test fixture

    /// Builds a lightweight model for tests and previews without exposing
    /// LibTorrent types through the signature. `stateName` uses the engine
    /// state's raw names ("downloading", "paused", "seeding", "finished",
    /// "storageError", "checkingFiles", "downloadingMetadata",
    /// "checkingResumeData").
    public static func makeStub(
        id: String,
        name: String,
        stateName: String = "downloading",
        progress: Double = 0.5,
        downloadRate: Int64 = 0,
        uploadRate: Int64 = 0,
        total: Int64 = 100,
        totalDone: Int64 = 50,
        isStalled: Bool = false,
        isPaused: Bool = false,
        isSeed: Bool = false,
        isFinished: Bool = false,
        createdAt: Date = Date()
    ) -> TorrentTaskModel {
        TorrentTaskModel(
            id: id,
            name: name,
            state: state(for: stateName),
            progress: progress,
            downloadRate: downloadRate,
            uploadRate: uploadRate,
            eta: nil,
            downloadLimit: -1,
            uploadLimit: -1,
            total: total,
            totalDone: totalDone,
            totalDownload: totalDone,
            totalUpload: 0,
            seeds: 0,
            peers: 0,
            leechers: 0,
            totalSeeds: 0,
            totalPeers: 0,
            totalLeechers: 0,
            files: [],
            trackers: [],
            magnetLink: nil,
            comment: nil,
            creator: nil,
            creationDate: nil,
            addedDate: nil,
            createdAt: createdAt,
            downloadPath: nil,
            pieceLength: 0,
            pieceCount: 0,
            isStalled: isStalled,
            isPaused: isPaused,
            isSeed: isSeed,
            isFinished: isFinished,
            stopSeeding: false,
            isSequential: false,
            isFirstLastPiecePriority: false
        )
    }

    private static func state(for name: String) -> TorrentHandle.State {
        switch name {
        case "paused": return .paused
        case "seeding": return .seeding
        case "finished": return .finished
        case "storageError": return .storageError
        case "checkingFiles": return .checkingFiles
        case "downloadingMetadata": return .downloadingMetadata
        case "checkingResumeData": return .checkingResumeData
        default: return .downloading
        }
    }
}

// MARK: - State display helpers

extension TorrentHandle.State {
    public var displayTitle: String {
        switch self {
        case .checkingFiles: return "Checking Files"
        case .checkingResumeData: return "Checking Resume Data"
        case .downloadingMetadata: return "Fetching Metadata"
        case .downloading: return "Downloading"
        case .finished: return "Completed"
        case .seeding: return "Seeding"
        case .paused: return "Paused"
        case .storageError: return "Storage Error"
        }
    }

    /// Stable ordering used by status-based sorting.
    public var sortRank: Int {
        switch self {
        case .downloadingMetadata: return 0
        case .checkingResumeData: return 1
        case .checkingFiles: return 2
        case .downloading: return 3
        case .finished: return 4
        case .seeding: return 5
        case .paused: return 6
        case .storageError: return 7
        }
    }
}