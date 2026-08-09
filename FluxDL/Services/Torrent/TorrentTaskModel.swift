import Foundation
import LibTorrent

// MARK: - TorrentFileItem

public struct TorrentFileItem: Identifiable, Equatable {
    public let index: Int
    public let name: String
    public let size: Int64
    public let downloaded: Int64
    public let priority: FileEntry.Priority

    public var id: Int { index }
}

// MARK: - TorrentTaskModel

public struct TorrentTaskModel: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var state: TorrentHandle.State
    public var progress: Double
    public var downloadRate: Int64
    public var uploadRate: Int64
    public var total: Int64
    public var totalDone: Int64
    public var seeds: Int
    public var peers: Int
    public var totalSeeds: Int
    public var totalPeers: Int
    public var files: [TorrentFileItem]
    public var trackers: [TorrentTrackerItem]
    public var magnetLink: String?
    public var comment: String?
    public var creator: String?
    public var creationDate: Date?
    public var isPaused: Bool
    public var isSeed: Bool
    public var isFinished: Bool
}

// MARK: - TorrentTrackerItem

public struct TorrentTrackerItem: Identifiable, Equatable {
    public let url: String
    public let state: TorrentTracker.State
    public let seeds: Int
    public let peers: Int
    public let leeches: Int
    public let message: String?

    public var id: String { url }
}
