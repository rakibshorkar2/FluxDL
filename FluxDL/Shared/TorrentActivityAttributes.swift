import ActivityKit

/// Attribute contract for the torrent Live Activity.
///
/// THIS FILE IS COMPILED INTO BOTH THE APP TARGET AND THE FluxDLWidgets
/// WIDGET EXTENSION TARGET. ActivityKit matches the two sides of a Live
/// Activity by the attributes type's name and Codable shape, so the type
/// must be defined by a single source file that is a member of both
/// targets. Keep it free of any FluxDL app types (no TorrentTaskModel,
/// no LibTorrent, no proxy/download/browser types).
public struct TorrentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var torrentName: String
        public var progress: Double
        public var downloadedSize: String
        public var totalSize: String
        public var downloadSpeed: String
        public var uploadSpeed: String
        public var status: String
    }

    public var infoHash: String
}