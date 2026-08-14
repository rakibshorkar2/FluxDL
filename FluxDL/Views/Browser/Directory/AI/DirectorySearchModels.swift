import Foundation

/// Structured search intent. `textTerms` are always populated by the local
/// query parser; the remaining fields may be filled by Gemini's query
/// interpretation to turn natural language into exact filters.
public struct DirectorySearchQuery: Equatable, Sendable {
    public var textTerms: [String]
    public var year: Int?
    public var resolution: String?
    public var mediaType: DirectoryItemType?
    public var fileExtension: String?
    public var minSizeBytes: Int64?
    public var maxSizeBytes: Int64?
    public var sort: DirectorySearchSortOption

    public init(
        textTerms: [String] = [],
        year: Int? = nil,
        resolution: String? = nil,
        mediaType: DirectoryItemType? = nil,
        fileExtension: String? = nil,
        minSizeBytes: Int64? = nil,
        maxSizeBytes: Int64? = nil,
        sort: DirectorySearchSortOption = .relevance
    ) {
        self.textTerms = textTerms
        self.year = year
        self.resolution = resolution
        self.mediaType = mediaType
        self.fileExtension = fileExtension
        self.minSizeBytes = minSizeBytes
        self.maxSizeBytes = maxSizeBytes
        self.sort = sort
    }

    public var isEmpty: Bool {
        textTerms.isEmpty && year == nil && resolution == nil
            && mediaType == nil && fileExtension == nil
            && minSizeBytes == nil && maxSizeBytes == nil
    }

    /// Whether the query carries structured filters beyond plain terms —
    /// used to decide whether Gemini actually refined the user's intent.
    public var hasStructuredFilters: Bool {
        year != nil || resolution != nil || mediaType != nil
            || fileExtension != nil || minSizeBytes != nil || maxSizeBytes != nil
    }
}

/// Result ordering for a global directory search.
public enum DirectorySearchSortOption: String, CaseIterable, Sendable {
    case relevance
    case sizeDescending
    case dateDescending

    public var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .sizeDescending: return "Size (largest first)"
        case .dateDescending: return "Date (newest first)"
        }
    }
}

/// One indexed file of an Open Directory root.
///
/// `id` is the file's absolute URL string — stable across parses so a search
/// result can be mapped back onto a freshly loaded directory listing for
/// highlighting.
public struct DirectorySearchEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let filename: String
    public let normalizedFilename: String
    public let tokens: [String]
    public let absoluteURL: String
    /// Server-side folder path relative to the indexed root (no filename),
    /// e.g. `"Animation Movies-1080p/A Bugs Life (1998) 1080p"`.
    public let relativePath: String
    public let parentDirectoryURL: String
    public let parentDirectoryPath: String
    public let fileExtension: String?
    public let type: DirectoryItemType
    public let sizeBytes: Int64?
    public let modifiedDate: Date?
    public let mimeType: String?
    /// Media metadata tokens (resolution, codec, source, year) extracted
    /// from the filename — used for metadata-ranked matching.
    public let metadataTokens: [String]
    public let year: Int?
    public let resolution: String?

    public init(
        id: String,
        filename: String,
        normalizedFilename: String,
        tokens: [String],
        absoluteURL: String,
        relativePath: String,
        parentDirectoryURL: String,
        parentDirectoryPath: String,
        fileExtension: String?,
        type: DirectoryItemType,
        sizeBytes: Int64?,
        modifiedDate: Date?,
        mimeType: String?,
        metadataTokens: [String],
        year: Int?,
        resolution: String?
    ) {
        self.id = id
        self.filename = filename
        self.normalizedFilename = normalizedFilename
        self.tokens = tokens
        self.absoluteURL = absoluteURL
        self.relativePath = relativePath
        self.parentDirectoryURL = parentDirectoryURL
        self.parentDirectoryPath = parentDirectoryPath
        self.fileExtension = fileExtension
        self.type = type
        self.sizeBytes = sizeBytes
        self.modifiedDate = modifiedDate
        self.mimeType = mimeType
        self.metadataTokens = metadataTokens
        self.year = year
        self.resolution = resolution
    }
}

/// One ranked search hit.
public struct DirectorySearchResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let entry: DirectorySearchEntry
    public let score: Double
    /// Query terms that contributed to the match (informational).
    public let matchedTerms: [String]

    public init(entry: DirectorySearchEntry, score: Double, matchedTerms: [String]) {
        self.id = entry.id
        self.entry = entry
        self.score = score
        self.matchedTerms = matchedTerms
    }

    /// Builds a `DirectoryItem` from the indexed entry so the existing
    /// Directory Mode actions (download, play, share, bookmark, …) can be
    /// reused unchanged.
    public var asDirectoryItem: DirectoryItem {
        DirectoryItem(
            name: entry.filename,
            url: URL(string: entry.absoluteURL) ?? URL(fileURLWithPath: entry.absoluteURL),
            type: entry.type,
            sizeBytes: entry.sizeBytes,
            modifiedDate: entry.modifiedDate,
            mimeType: entry.mimeType
        )
    }
}

/// Strict, validated JSON payload returned by the Gemini query interpreter.
///
/// Only this Codable shape is ever accepted; any other Gemini output is
/// rejected and the search falls back to local matching.
public struct DirectorySearchIntent: Codable, Sendable {
    public var textTerms: [String]?
    public var year: Int?
    public var resolution: String?
    public var mediaType: String?
    public var fileExtension: String?
    public var minSizeGB: Double?
    public var maxSizeGB: Double?
    public var sort: String?

    public init(
        textTerms: [String]? = nil,
        year: Int? = nil,
        resolution: String? = nil,
        mediaType: String? = nil,
        fileExtension: String? = nil,
        minSizeGB: Double? = nil,
        maxSizeGB: Double? = nil,
        sort: String? = nil
    ) {
        self.textTerms = textTerms
        self.year = year
        self.resolution = resolution
        self.mediaType = mediaType
        self.fileExtension = fileExtension
        self.minSizeGB = minSizeGB
        self.maxSizeGB = maxSizeGB
        self.sort = sort
    }
}