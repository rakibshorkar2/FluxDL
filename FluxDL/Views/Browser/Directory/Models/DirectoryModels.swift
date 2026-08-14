import Foundation

/// The two independent modes of the FluxDL Browser tab.
///
/// - `web`: the existing FluxDL Web Browser (WKWebView, tabs, private
///   browsing, ad blocking, find-in-page, reader mode, downloads).
/// - `directory`: the DirXplore-inspired Open Directory Browser.
public enum BrowserMode: String, CaseIterable, Sendable {
    case web
    case directory

    public var title: String {
        switch self {
        case .web: return "Web"
        case .directory: return "Directory"
        }
    }

    public var systemImage: String {
        switch self {
        case .web: return "globe"
        case .directory: return "folder"
        }
    }
}

/// File/folder classification of a directory entry.
public enum DirectoryItemType: String, CaseIterable, Codable, Sendable {
    case directory
    case video
    case audio
    case image
    case archive
    case document
    case other

    /// Classifies a filename by its extension (lowercased).
    public init(extension ext: String?) {
        guard let ext = ext?.lowercased(), !ext.isEmpty else {
            self = .other
            return
        }
        switch ext {
        case "mp4", "mkv", "avi", "mov", "wmv", "flv", "m4v", "webm", "ts", "m2ts":
            self = .video
        case "mp3", "flac", "aac", "ogg", "wav", "opus", "m4a", "wma":
            self = .audio
        case "jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "tiff":
            self = .image
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso":
            self = .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "txt", "epub", "mobi", "srt", "nfo":
            self = .document
        default:
            self = .other
        }
    }

    /// Whether in-app playback should be offered for this item.
    public var isPlayableMedia: Bool {
        self == .video || self == .audio
    }

    public var title: String {
        switch self {
        case .directory: return "Folder"
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Image"
        case .archive: return "Archive"
        case .document: return "Document"
        case .other: return "File"
        }
    }

    public var systemImage: String {
        switch self {
        case .directory: return "folder.fill"
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .archive: return "doc.zipper"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }
}

/// One entry of an open-directory listing.
///
/// Sizes are stored as raw byte counts (`Int64?`) and formatted only in the
/// UI, so sorting/filtering by size works on canonical values.
public struct DirectoryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let url: URL
    public let type: DirectoryItemType
    public let sizeBytes: Int64?
    public let modifiedDate: Date?
    public let mimeType: String?
    /// Optional entry count for directories (set by the parser when the
    /// server exposes it, e.g. "1 directory, 5 files").
    public let childCount: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        type: DirectoryItemType,
        sizeBytes: Int64?,
        modifiedDate: Date? = nil,
        mimeType: String? = nil,
        childCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.type = type
        self.sizeBytes = sizeBytes
        self.modifiedDate = modifiedDate
        self.mimeType = mimeType
        self.childCount = childCount
    }

    /// "4.8 GB", "512 MB", "12 KB" or nil when the size is unknown.
    public var formattedSize: String? {
        DirectoryItemFormatter.string(fromBytes: sizeBytes)
    }

    /// Returns a copy with the byte count replaced — used when a missing
    /// size is resolved later (e.g. via a HEAD request) without losing the
    /// item's identity, selection or metadata.
    public func withSize(_ bytes: Int64?) -> DirectoryItem {
        DirectoryItem(
            id: id,
            name: name,
            url: url,
            type: type,
            sizeBytes: bytes,
            modifiedDate: modifiedDate,
            mimeType: mimeType,
            childCount: childCount
        )
    }

    /// File extension without the leading dot, or nil for folders.
    public var fileExtension: String? {
        guard type != .directory else { return nil }
        return (name as NSString).pathExtension.isEmpty ? nil : (name as NSString).pathExtension
    }
}

/// Byte/date display formatting shared by directory UI.
public enum DirectoryItemFormatter {
    /// "1.48 GB", "512 MB", "12 KB", "0 B" — or "Unknown size" when the byte
    /// count is missing. Binary units (1024), matching the app's
    /// `ByteCountFormatter` convention elsewhere; whole-unit values drop the
    /// decimal ("1 KB", never "1.0 KB").
    public static func formattedFileSize(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "Unknown size" }
        if bytes == 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(bytes) B"
        }
        let trimmed = String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(trimmed) \(units[index])"
    }

    /// Byte formatting for contexts that treat "unknown" as absence (nil).
    public static func string(fromBytes bytes: Int64?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        return formattedFileSize(bytes)
    }

    public static func string(fromDate date: Date?) -> String? {
        dateString(date)
    }

    public static func dateString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// Category filter for a parsed directory (DirXplore-inspired keyword model).
public enum DirectoryCategory: String, CaseIterable, Sendable {
    case all
    case movies
    case series
    case games
    case software
    case anime
    case images

    public var title: String {
        switch self {
        case .all: return "All"
        case .movies: return "Movies"
        case .series: return "Series / TV"
        case .games: return "Games"
        case .software: return "Software"
        case .anime: return "Anime"
        case .images: return "Images"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .movies: return "film"
        case .series: return "tv"
        case .games: return "gamecontroller"
        case .software: return "shippingbox"
        case .anime: return "sparkles"
        case .images: return "photo"
        }
    }

    private var keywords: [String] {
        switch self {
        case .all: return []
        case .movies: return ["1080p", "720p", "bluray", "mkv", "mp4", "avi", "movie"]
        case .series: return ["s01", "e01", "season", "episode", "hdtv"]
        case .games: return ["repack", "iso", "codex", "skidrow", "fitgirl", "pc"]
        case .software: return ["crack", "keygen", "setup", "exe", "mac", "win"]
        case .anime: return ["anime", "sub", "dub", "1080p", "720p", "mkv"]
        case .images: return ["jpg", "png", "gif", "jpeg", "webp"]
        }
    }

    /// A category match is purely name/keyword based — never downloads files.
    /// Directories always pass so navigation stays possible.
    public func matches(_ item: DirectoryItem) -> Bool {
        guard self != .all else { return true }
        if item.type == .directory { return true }
        let name = item.name.lowercased()
        return keywords.contains { name.contains($0) }
    }
}

/// Local sorting for the currently parsed directory (server is never touched).
public enum DirectorySortOption: String, CaseIterable, Sendable {
    case foldersFirst
    case nameAscending
    case nameDescending
    case sizeDescending
    case dateDescending

    public var title: String {
        switch self {
        case .foldersFirst: return "Folders First"
        case .nameAscending: return "Name A → Z"
        case .nameDescending: return "Name Z → A"
        case .sizeDescending: return "Size (largest first)"
        case .dateDescending: return "Date (newest first)"
        }
    }

    public func sorted(_ items: [DirectoryItem]) -> [DirectoryItem] {
        let folders = items.filter { $0.type == .directory }
        let files = items.filter { $0.type != .directory }
        switch self {
        case .foldersFirst:
            return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                + files.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameAscending:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .sizeDescending:
            let folderSorted = folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let fileSorted = files.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
            return folderSorted + fileSorted
        case .dateDescending:
            let folderSorted = folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let fileSorted = files.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
            return folderSorted + fileSorted
        }
    }
}