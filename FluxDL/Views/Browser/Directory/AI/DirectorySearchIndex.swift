import Foundation

// MARK: - Root key normalization

/// Stable identity for one Open Directory root: `scheme://host[:port]` plus a
/// normalized (`.`, `..`-resolved, trailing-slash) path. Two roots never share
/// an index — different servers, ports, schemes or paths are distinct keys.
public enum DirectorySearchRootKey {

    /// Resolves `.`/`..` segments and guarantees a trailing slash, mirroring
    /// the crawler's path handling so hostile links cannot climb out.
    public static func normalizedPath(_ path: String) -> String {
        var stack: [String] = []
        for component in path.split(separator: "/") {
            let c = String(component)
            if c == "." || c.isEmpty { continue }
            if c == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(c)
        }
        var result = "/" + stack.joined(separator: "/")
        if !result.hasSuffix("/") { result += "/" }
        return result
    }

    /// Canonical root URL (host lowercased, path normalized).
    public static func normalizedRootURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = url.host?.lowercased()
        components.port = url.port
        components.path = normalizedPath(url.path)
        return components.url
    }

    /// The stable key: `"http://host:8080/path/"` (port included only when
    /// the URL carries one).
    public static func key(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return url.absoluteString
        }
        var result = "\(scheme)://\(host)"
        if let port = url.port {
            result += ":\(port)"
        }
        return result + normalizedPath(url.path)
    }

    /// Portable file-safe hash of a root key (hex of its UTF-8 bytes).
    public static func cacheFileName(for key: String) -> String {
        key.utf8.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Filename normalization & media metadata

/// Splits media filenames into searchable tokens and recognizes common media
/// metadata (resolution, codec, source, year, season/episode).
public enum DirectoryFilenameNormalizer {

    /// Separators: every run of non-alphanumeric characters (Unicode-aware).
    /// `"A.Bugs.Life.1998.1080p.BluRay.x264.YIFY.mp4"` →
    /// `["a", "bugs", "life", "1998", "1080p", "bluray", "x264", "yify", "mp4"]`.
    public static func tokens(from raw: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return raw.lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    /// Tokens joined by single spaces — the canonical normalized form.
    public static func normalized(from raw: String) -> String {
        tokens(from: raw).joined(separator: " ")
    }

    // MARK: Media metadata

    private static let yearPattern = #"\b(19[0-9]{2}|20[0-9]{2})\b"#

    /// First plausible release year in the raw string (1900–2099).
    public static func year(in raw: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: yearPattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              let tokenRange = Range(match.range(at: 0), in: raw),
              let value = Int(String(raw[tokenRange])) else { return nil }
        return value
    }

    /// Canonical resolution of a token, or nil. `"4K"`/`"UHD"` canonicalize to
    /// `"2160p"` so both spellings match.
    public static func canonicalResolution(for token: String) -> String? {
        switch token.lowercased() {
        case "480p", "480i": return "480p"
        case "576p": return "576p"
        case "720p", "720i": return "720p"
        case "1080p", "1080i", "fhd": return "1080p"
        case "1440p", "qhd": return "1440p"
        case "2160p", "4k", "uhd", "4kuhd": return "2160p"
        case "8k", "8kuhd": return "8k"
        default: return nil
        }
    }

    /// Recognized resolution in a filename (first hit wins).
    public static func resolution(in raw: String) -> String? {
        for token in tokens(from: raw) {
            if let canonical = canonicalResolution(for: token) {
                return canonical
            }
        }
        return nil
    }

    /// All resolution variants an entry can match against
    /// (`"4K"` → `["2160p", "4k"]`).
    public static func resolutionVariants(for raw: String) -> [String] {
        var variants: [String] = []
        for token in tokens(from: raw) {
            let lowered = token.lowercased()
            if let canonical = canonicalResolution(for: lowered), !variants.contains(canonical) {
                variants.append(canonical)
            }
            if lowered == "4k" || lowered == "uhd" || lowered == "4kuhd" {
                if !variants.contains("4k") { variants.append("4k") }
            }
            if lowered == "8k" && !variants.contains("8k") { variants.append("8k") }
        }
        return variants
    }

    private static let codecTokens: Set<String> = [
        "x264", "h264", "x265", "h265", "hevc", "avc", "vp9", "av1", "mpeg4", "divx"
    ]
    private static let sourceTokens: Set<String> = [
        "webdl", "web-dl", "webrip", "bluray", "brrip", "bdrip", "hdtv",
        "dvdrip", "remux", "hdr", "dv", "sdr", "hdr10", "hdr10+"
    ]

    /// Media metadata tokens of a filename: resolution variants, codec,
    /// source/quality markers, year and season/episode tags.
    public static func metadataTokens(in raw: String) -> [String] {
        var result: [String] = []
        for token in tokens(from: raw) {
            let lowered = token.lowercased()
            if codecTokens.contains(lowered) || sourceTokens.contains(lowered) {
                result.append(lowered)
            } else if let canonical = canonicalResolution(for: lowered) {
                result.append(canonical)
                if lowered == "4k" || lowered == "uhd" { result.append("4k") }
            } else if isSeasonEpisodeToken(lowered) {
                result.append(lowered)
            }
        }
        if let year = year(in: raw) {
            result.append(String(year))
        }
        return result
    }

    /// `s01` / `e05` style season/episode tags.
    public static func isSeasonEpisodeToken(_ token: String) -> Bool {
        token.range(of: #"^(s|e|se)\d{1,2}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Index

/// The searchable snapshot of one Open Directory root.
public struct DirectorySearchIndex: Codable, Equatable, Sendable {
    public let rootKey: String
    public let rootURL: String
    public var entries: [DirectorySearchEntry]
    /// True when the crawl hit its safety cap (or was aborted) — the server
    /// may hold more files than this index contains.
    public var isPartial: Bool
    public var completedAt: Date?
    public var foldersScanned: Int
    public var failedFolders: [String]

    public init(
        rootKey: String,
        rootURL: String,
        entries: [DirectorySearchEntry],
        isPartial: Bool,
        completedAt: Date? = nil,
        foldersScanned: Int = 0,
        failedFolders: [String] = []
    ) {
        self.rootKey = rootKey
        self.rootURL = rootURL
        self.entries = entries
        self.isPartial = isPartial
        self.completedAt = completedAt
        self.foldersScanned = foldersScanned
        self.failedFolders = failedFolders
    }
}

/// Builds a `DirectorySearchIndex` from crawl results. Pure and offline —
/// never touches the network.
public enum DirectorySearchIndexBuilder {

    public static func build(
        files: [CrawledFile],
        root: URL,
        foldersScanned: Int = 0,
        failedFolders: [String] = [],
        isPartial: Bool = false
    ) -> DirectorySearchIndex {
        let entries = files.map { entry(from: $0) }
        return DirectorySearchIndex(
            rootKey: DirectorySearchRootKey.key(for: root),
            rootURL: DirectorySearchRootKey.normalizedRootURL(for: root)?.absoluteString ?? root.absoluteString,
            entries: entries,
            isPartial: isPartial,
            completedAt: Date(),
            foldersScanned: foldersScanned,
            failedFolders: failedFolders
        )
    }

    /// Percent-decoded folder path of an entry (`""` at the root).
    public static func folderPath(for file: CrawledFile) -> String {
        let rawPath = (file.relativePath as NSString).deletingLastPathComponent
        guard !rawPath.isEmpty else { return "" }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        return decoded
    }

    public static func folderTokens(for file: CrawledFile) -> [String] {
        var tokens: [String] = []
        let path = folderPath(for: file)
        for component in path.split(separator: "/") {
            tokens.append(contentsOf: DirectoryFilenameNormalizer.tokens(from: String(component)))
        }
        return tokens
    }

    private static func entry(from file: CrawledFile) -> DirectorySearchEntry {
        let urlString = file.url.absoluteString
        let extensionName = file.type == .directory
            ? nil
            : ((file.name as NSString).pathExtension.isEmpty ? nil : (file.name as NSString).pathExtension)
        let normalizedFilename = DirectoryFilenameNormalizer.normalized(from: file.name)
        var tokens = DirectoryFilenameNormalizer.tokens(from: file.name)
        tokens.append(contentsOf: folderTokens(for: file))
        if let extensionName, !extensionName.isEmpty {
            tokens.append(extensionName.lowercased())
        }
        let metadata = DirectoryFilenameNormalizer.metadataTokens(in: file.name)
        tokens.append(contentsOf: metadata)

        let parentURL = file.url.deletingLastPathComponent()

        return DirectorySearchEntry(
            id: urlString,
            filename: file.name,
            normalizedFilename: normalizedFilename,
            tokens: unique(tokens),
            absoluteURL: urlString,
            relativePath: folderPath(for: file),
            parentDirectoryURL: parentURL.absoluteString,
            parentDirectoryPath: (file.relativePath as NSString).deletingLastPathComponent,
            fileExtension: extensionName,
            type: file.type,
            sizeBytes: file.sizeBytes,
            modifiedDate: file.modifiedDate,
            mimeType: file.mimeType,
            metadataTokens: unique(metadata),
            year: DirectoryFilenameNormalizer.year(in: file.name),
            resolution: DirectoryFilenameNormalizer.resolution(in: file.name)
        )
    }

    private static func unique(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }
}

// MARK: - Local query parsing (no Gemini required)

/// Extracts structured intent from raw user text entirely locally: years,
/// resolutions, size constraints ("larger than 2 GB"), file types and
/// extensions ("mkv files"), season/episode expansions ("season 2 episode 5"
/// → `s02 e05`-style terms).
public enum DirectoryQueryParser {

    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "for", "with", "to", "and", "or",
        "find", "show", "me", "all", "any", "that", "this", "it", "is", "are",
        "files", "file", "folder", "folders", "larger", "smaller", "bigger",
        "than", "greater", "less", "under", "below", "above", "over", "more"
    ]

    private static let sizePattern =
        #"(larger|bigger|greater|more|above|over)\s+than\s+([0-9]+(?:\.[0-9]+)?)\s*(KB|MB|GB|TB|KIB|MIB|GIB|TIB)"#
    private static let sizeSmallPattern =
        #"(smaller|less|under|below)\s+than\s+([0-9]+(?:\.[0-9]+)?)\s*(KB|MB|GB|TB|KIB|MIB|GIB|TIB)"#

    public static func parse(_ raw: String) -> DirectorySearchQuery {
        var query = DirectorySearchQuery()
        var text = raw.lowercased()

        // Size constraints first — removed from the free-text stream.
        if let match = firstMatch(pattern: sizePattern, in: text),
           let bytes = bytes(from: match, in: text) {
            query.minSizeBytes = bytes
            text = removing(match.range, from: text)
        }
        if let match = firstMatch(pattern: sizeSmallPattern, in: text),
           let bytes = bytes(from: match, in: text) {
            query.maxSizeBytes = bytes
            text = removing(match.range, from: text)
        }

        var tokens = DirectoryFilenameNormalizer.tokens(from: text)

        // Extension tokens ("mkv files") become exact filters.
        let knownExtensions: Set<String> = [
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "m4v", "webm", "ts", "m2ts",
            "mp3", "flac", "aac", "ogg", "wav", "opus", "m4a", "wma",
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "tiff",
            "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso",
            "pdf", "doc", "docx", "xls", "xlsx", "txt", "epub", "mobi", "srt", "nfo"
        ]
        tokens = tokens.filter { token in
            if knownExtensions.contains(token) {
                query.fileExtension = token
                return false
            }
            return true
        }

        // "season 2 episode 5" → add s02/e05 style tokens so entry
        // season/episode metadata participates in matching.
        if let season = seasonNumber(in: tokens) {
            tokens.append(String(format: "s%02d", season))
        }
        if let episode = episodeNumber(in: tokens) {
            tokens.append(String(format: "e%02d", episode))
        }

        // Media-type keywords.
        let typeKeywords: [(Set<String>, DirectoryItemType)] = [
            (["video", "movie", "movies", "film", "films", "series", "episode", "show", "tv"], .video),
            (["audio", "music", "song", "songs", "album", "soundtrack"], .audio),
            (["image", "images", "picture", "pictures", "photo", "photos"], .image),
            (["archive", "archives", "zip", "rar", "compressed"], .archive),
            (["document", "documents", "documentation", "ebook", "book", "books"], .document)
        ]
        for (keywords, type) in typeKeywords {
            let matched = tokens.filter { keywords.contains($0) }
            if !matched.isEmpty {
                query.mediaType = type
                tokens.removeAll { keywords.contains($0) }
            }
        }

        // Year + resolution extraction.
        query.year = DirectoryFilenameNormalizer.year(in: tokens.joined(separator: " "))
        tokens.removeAll { token in
            if token.range(of: #"^(19[0-9]{2}|20[0-9]{2})$"#, options: .regularExpression) != nil {
                return true
            }
            if let canonical = DirectoryFilenameNormalizer.canonicalResolution(for: token) {
                query.resolution = canonical
                return true
            }
            return false
        }

        query.textTerms = tokens.filter { !stopwords.contains($0) }
        return query
    }

    private static func seasonNumber(in tokens: [String]) -> Int? {
        guard let idx = tokens.firstIndex(of: "season"), idx + 1 < tokens.count,
              let value = Int(tokens[idx + 1]), (1...99).contains(value) else { return nil }
        return value
    }

    private static func episodeNumber(in tokens: [String]) -> Int? {
        guard let idx = tokens.firstIndex(of: "episode"), idx + 1 < tokens.count,
              let value = Int(tokens[idx + 1]), (1...99).contains(value) else { return nil }
        return value
    }

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    /// Removes the matched range from the string. Stale ranges (e.g. after
    /// an earlier removal shifted indices) are rejected safely.
    private static func removing(_ nsRange: NSRange, from text: String) -> String {
        guard let range = Range(nsRange, in: text) else { return text }
        var result = text
        result.removeSubrange(range)
        return result
    }

    private static func bytes(from match: NSTextCheckingResult, in text: String) -> Int64? {
        guard match.numberOfRanges == 4,
              let valueRange = Range(match.range(at: 2), in: text),
              let unitRange = Range(match.range(at: 3), in: text),
              let value = Double(String(text[valueRange])) else { return nil }
        let multiplier: Double
        switch String(text[unitRange]).uppercased() {
        case "KB", "KIB": multiplier = 1024
        case "MB", "MIB": multiplier = 1024 * 1024
        case "GB", "GIB": multiplier = 1024 * 1024 * 1024
        case "TB", "TIB": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(value * multiplier)
    }
}

// MARK: - Local search engine

/// Pure, offline ranking over one index. Ties broken by filename.
public enum DirectorySearchEngine {

    public static func search(
        index: DirectorySearchIndex,
        query: DirectorySearchQuery,
        limit: Int = 50
    ) -> [DirectorySearchResult] {
        guard !query.isEmpty else { return [] }
        let normalizedQuery = query.textTerms.joined(separator: " ")
        let terms = query.textTerms

        var scored: [DirectorySearchResult] = []
        for entry in index.entries {
            guard sizeFilterPasses(entry: entry, query: query) else { continue }
            guard typeFilterPasses(entry: entry, query: query) else { continue }
            guard extensionFilterPasses(entry: entry, query: query) else { continue }
            guard yearFilterPasses(entry: entry, query: query) else { continue }
            guard resolutionFilterPasses(entry: entry, query: query) else { continue }

            guard !terms.isEmpty else {
                scored.append(DirectorySearchResult(entry: entry, score: 1, matchedTerms: []))
                continue
            }

            let (score, matched) = score(entry: entry, terms: terms, normalizedQuery: normalizedQuery)
            guard score > 0, !matched.isEmpty else { continue }
            scored.append(DirectorySearchResult(entry: entry, score: score, matchedTerms: matched))
        }

        switch query.sort {
        case .relevance:
            scored.sort { lhs, rhs in
                lhs.score == rhs.score
                    ? lhs.entry.filename.localizedCaseInsensitiveCompare(rhs.entry.filename) == .orderedAscending
                    : lhs.score > rhs.score
            }
        case .sizeDescending:
            scored.sort { ($0.entry.sizeBytes ?? 0) > ($1.entry.sizeBytes ?? 0) }
        case .dateDescending:
            scored.sort { ($0.entry.modifiedDate ?? .distantPast) > ($1.entry.modifiedDate ?? .distantPast) }
        }

        return Array(scored.prefix(limit))
    }

    // MARK: Mandatory filters

    private static func sizeFilterPasses(entry: DirectorySearchEntry, query: DirectorySearchQuery) -> Bool {
        guard let size = entry.sizeBytes else {
            // Unknown sizes can never be proven inside a range — excluded
            // only when a size filter is actually requested.
            return query.minSizeBytes == nil && query.maxSizeBytes == nil
        }
        if let min = query.minSizeBytes, size < min { return false }
        if let max = query.maxSizeBytes, size > max { return false }
        return true
    }

    private static func typeFilterPasses(entry: DirectorySearchEntry, query: DirectorySearchQuery) -> Bool {
        guard let type = query.mediaType else { return true }
        return entry.type == type
    }

    private static func extensionFilterPasses(entry: DirectorySearchEntry, query: DirectorySearchQuery) -> Bool {
        guard let ext = query.fileExtension else { return true }
        return entry.fileExtension?.lowercased() == ext.lowercased()
    }

    private static func yearFilterPasses(entry: DirectorySearchEntry, query: DirectorySearchQuery) -> Bool {
        guard let year = query.year else { return true }
        return entry.year == year
    }

    private static func resolutionFilterPasses(entry: DirectorySearchEntry, query: DirectorySearchQuery) -> Bool {
        guard let resolution = query.resolution else { return true }
        return DirectoryFilenameNormalizer.resolutionVariants(for: entry.filename)
            .contains(resolution.lowercased())
    }

    // MARK: Scoring

    private static func score(
        entry: DirectorySearchEntry,
        terms: [String],
        normalizedQuery: String
    ) -> (Double, [String]) {
        var score: Double = 0
        var matched: [String] = []
        let filenameTokens = Set(entry.tokens)

        if entry.normalizedFilename == normalizedQuery {
            score += 500
            matched.append(contentsOf: terms)
        } else if entry.normalizedFilename.contains(normalizedQuery) {
            score += 260
            matched.append(contentsOf: terms)
        }

        var allInFilename = true
        for term in terms {
            guard filenameTokens.contains(term) else {
                allInFilename = false
                break
            }
        }
        if allInFilename {
            score += 180
            if matched.isEmpty { matched.append(contentsOf: terms) }
        }

        let pathTokens = Set(DirectoryFilenameNormalizer.tokens(from: entry.relativePath))
        for term in terms {
            if filenameTokens.contains(term) {
                score += 25
                if !matched.contains(term) { matched.append(term) }
            } else if entry.metadataTokens.contains(term) {
                score += 15
                if !matched.contains(term) { matched.append(term) }
            } else if pathTokens.contains(term) {
                score += 8
                if !matched.contains(term) { matched.append(term) }
            } else if fuzzyMatch(term: term, in: entry) {
                score += 5
                if !matched.contains(term) { matched.append(term) }
            }
        }

        if let resolution = DirectoryFilenameNormalizer.resolution(in: entry.filename),
           let canonical = DirectoryFilenameNormalizer.canonicalResolution(for: resolution) {
            // Metadata agreement between query and filename is a ranking
            // signal (already counted as a token above when present).
            if entry.metadataTokens.contains(canonical) {
                score += 10
            }
        }

        // Density bonus: shorter filenames rank higher for equal matches.
        score += 4 / (1 + Double(entry.tokens.count))
        return (score, matched)
    }

    /// Prefix (term ≥ 3 chars) or substring (term ≥ 4 chars) match against
    /// any filename/path token — tolerant of typos and glued tokens.
    private static func fuzzyMatch(term: String, in entry: DirectorySearchEntry) -> Bool {
        guard term.count >= 3 else { return false }
        let minimumSubstringLength = 4
        for token in entry.tokens {
            if token.hasPrefix(term) { return true }
            if term.count >= minimumSubstringLength, token.contains(term) { return true }
        }
        return false
    }
}