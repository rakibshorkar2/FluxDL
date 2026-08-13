import Foundation

/// How a listing page looks, used for detection and diagnostics.
public enum DirectoryListingStyle: String, Sendable {
    case apache
    case nginx
    case generic
    case none
}

/// Result of parsing a fetched page: the extracted items plus the signals
/// used to decide whether the page is actually an open directory.
public struct DirectoryParseResult: Sendable, Equatable {
    public var items: [DirectoryItem]
    public var isHTML: Bool
    public var hasParentLink: Bool
    public var hasListingMarker: Bool
    public var hasTable: Bool
    public var anchorCount: Int
    public var directoryAnchorCount: Int
    public var listingStyle: DirectoryListingStyle
}

/// Parses Apache / Nginx / generic HTML open-directory listings.
///
/// Pure and `Sendable` — callers run it off the main thread (e.g. inside
/// `Task.detached`) so large pages never block the UI.
public enum DirectoryHTMLParser {

    // MARK: - Entry point

    public static func parse(html: Data, baseURL: URL) -> DirectoryParseResult {
        guard let raw = String(data: html, encoding: .utf8)
            ?? String(data: html, encoding: .isoLatin1) else {
            return DirectoryParseResult(
                items: [], isHTML: false, hasParentLink: false, hasListingMarker: false,
                hasTable: false, anchorCount: 0, directoryAnchorCount: 0, listingStyle: .none
            )
        }
        return parse(html: raw, baseURL: baseURL)
    }

    public static func parse(html: String, baseURL: URL) -> DirectoryParseResult {
        let lowered = html.lowercased()
        let isHTML = lowered.contains("<html") || lowered.contains("<!doctype")
        let hasTable = lowered.contains("<table")
        let hasListingMarker = lowered.contains("index of")
            || lowered.contains("parent directory")
            || lowered.contains("directory listing")

        var items: [DirectoryItem] = []
        var hasParentLink = false
        var directoryAnchorCount = 0

        let anchorRegex = try? NSRegularExpression(
            pattern: "<a\\s+[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )

        if let anchorRegex {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = anchorRegex.matches(in: html, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let hrefRange = Range(match.range(at: 1), in: html),
                      let textRange = Range(match.range(at: 2), in: html) else { continue }

                let rawHref = String(html[hrefRange])
                var text = String(html[textRange])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let href = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
                if href.isEmpty { continue }
                if href.hasPrefix("?") || href.hasPrefix("#") { continue }
                if href.lowercased().hasPrefix("mailto:")
                    || href.lowercased().hasPrefix("javascript:")
                    || href.lowercased().hasPrefix("tel:") { continue }
                if href == "/" || href == "./" || href == "." { continue }
                if href == "../" || href == ".." || href.hasPrefix("../") {
                    hasParentLink = true
                    continue
                }

                let loweredText = text.lowercased()
                if ["name", "size", "date", "description", "last modified", "type", "modified"]
                    .contains(loweredText) { continue }

                guard let resolved = resolve(href, base: baseURL) else { continue }
                let isDirectory = href.hasSuffix("/") || resolved.path.hasSuffix("/")
                if isDirectory {
                    directoryAnchorCount += 1
                }
                if resolved == baseURL { continue }
                if text.isEmpty {
                    text = displayName(from: resolved)
                }
                if text.isEmpty { continue }
                if text.hasSuffix("/") {
                    text = String(text.dropLast())
                }

                let (size, date) = extractRowMetadata(ns: html as NSString, matchRange: match.range)
                let type: DirectoryItemType = isDirectory ? .directory : DirectoryItemType(extension: (text as NSString).pathExtension)
                items.append(DirectoryItem(name: text, url: resolved, type: type, sizeBytes: size, modifiedDate: date))
            }
        }

        let style: DirectoryListingStyle
        if lowered.contains("apache") || (hasTable && items.contains(where: { $0.sizeBytes != nil })) {
            style = .apache
        } else if lowered.contains("nginx") || (!hasTable && items.contains(where: { $0.sizeBytes != nil || $0.modifiedDate != nil })) {
            style = .nginx
        } else if isHTML && (hasParentLink || !items.isEmpty) {
            style = .generic
        } else {
            style = .none
        }

        return DirectoryParseResult(
            items: items,
            isHTML: isHTML,
            hasParentLink: hasParentLink,
            hasListingMarker: hasListingMarker,
            hasTable: hasTable,
            anchorCount: items.count,
            directoryAnchorCount: directoryAnchorCount,
            listingStyle: style
        )
    }

    // MARK: - URL resolution

    /// Resolves a possibly-relative href against the page URL.
    /// Never concatenates strings — always goes through `URL`.
    private static func resolve(_ href: String, base: URL) -> URL? {
        if let url = URL(string: href, relativeTo: base)?.absoluteURL {
            return normalizedDirectoryURL(url, hrefEndsWithSlash: href.hasSuffix("/"))
        }
        if let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: encoded, relativeTo: base)?.absoluteURL {
            return normalizedDirectoryURL(url, hrefEndsWithSlash: href.hasSuffix("/"))
        }
        return nil
    }

    /// Guarantees directories carry a trailing slash so navigation stays on
    /// the directory and relative links resolve against it.
    private static func normalizedDirectoryURL(_ url: URL, hrefEndsWithSlash: Bool) -> URL {
        guard hrefEndsWithSlash, !url.path.hasSuffix("/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.path += "/"
        return components.url ?? url
    }

    /// Fallback display name from the resolved URL's last path segment,
    /// percent-decoded (Unicode filenames round-trip correctly).
    private static func displayName(from url: URL) -> String {
        let last = url.pathComponents.last ?? ""
        let decoded = last.removingPercentEncoding ?? last
        return decoded == "/" || decoded.isEmpty ? "" : decoded
    }

    // MARK: - Row metadata (size + date)

    /// Extracts size/date for the row that contains this anchor.
    ///
    /// Apache: `<td>` cells of the enclosing `<tr>` — the cell that looks
    /// like a size wins the size slot, the cell that looks like a date wins
    /// the date slot (layout-agnostic across 4/5-column variants).
    /// Nginx: the trailing text of the row after the anchor.
    private static func extractRowMetadata(ns: NSString, matchRange: NSRange) -> (Int64?, Date?) {
        let matchStart = matchRange.location
        if let (rowStart, rowEnd) = enclosingTableRow(ns: ns, anchorLocation: matchStart) {
            let row = ns.substring(with: NSRange(location: rowStart, length: rowEnd - rowStart))
            let cells = tableCells(in: row)
            if cells.count >= 4 {
                var size: Int64?
                var date: Date?
                for cell in cells {
                    let stripped = cell.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if date == nil, let parsed = parseDateToken(stripped) {
                        date = parsed
                    } else if size == nil, let parsed = parseSizeToken(stripped) {
                        size = parsed
                    }
                }
                return (size, date)
            }
        }

        let afterAnchor = ns.substring(from: matchStart + matchRange.length)
        let lineEnd = (afterAnchor as NSString).range(of: "\n")
        let remainder = lineEnd.location == NSNotFound
            ? afterAnchor
            : (afterAnchor as NSString).substring(to: lineEnd.location)
        let date = parseDateToken(remainder)
        let size = parseSizeToken(remainder)
        return (size, date)
    }

    private static func enclosingTableRow(ns: NSString, anchorLocation: Int) -> (Int, Int)? {
        let searchLength = min(anchorLocation, 40_000)
        let beforeStart = max(0, anchorLocation - searchLength)
        let before = ns.substring(with: NSRange(location: beforeStart, length: searchLength))
        let after = ns.substring(with: NSRange(location: anchorLocation, length: min(ns.length - anchorLocation, 20_000)))
        let openRange = (before as NSString).range(of: "<tr", options: .backwards)
        let closeRange = (after as NSString).range(of: "</tr>")
        guard openRange.location != NSNotFound, closeRange.location != NSNotFound else { return nil }
        return (beforeStart + openRange.location, anchorLocation + closeRange.location + closeRange.length)
    }

    private static func tableCells(in row: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "<td[^>]*>(.*?)</td>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let regex else { return [] }
        let range = NSRange(row.startIndex..<row.endIndex, in: row)
        return regex.matches(in: row, options: [], range: range).compactMap { match in
            guard let cellRange = Range(match.range(at: 1), in: row) else { return nil }
            return String(row[cellRange])
        }
    }

    // MARK: - Size parsing

    private static let sizeTokenPattern = #"([0-9]+(?:\.[0-9]+)?)\s*([KMGTP]?i?B?)"#

    /// Extracts a size token from a cell or trailing row text.
    private static func parseSizeToken(_ raw: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: sizeTokenPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: raw),
              let value = Double(String(raw[numberRange]).replacingOccurrences(of: ",", with: "")) else {
            return nil
        }
        var unit = ""
        if match.numberOfRanges > 2, let unitRange = Range(match.range(at: 2), in: raw) {
            unit = String(raw[unitRange]).uppercased()
        }
        let multiplier: Double
        switch unit {
        case "", "B": multiplier = 1
        case "K", "KB", "KIB": multiplier = 1024
        case "M", "MB", "MIB": multiplier = 1024 * 1024
        case "G", "GB", "GIB": multiplier = 1024 * 1024 * 1024
        case "T", "TB", "TIB": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }

    /// Strict full-string size parser used by tests (and the folder crawler
    /// aggregator when needed).
    public static func parseSize(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*[0-9]+(?:\.[0-9]+)?\s*[KMGTP]?i?B?\s*$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard regex.firstMatch(in: trimmed, options: [], range: range) != nil else { return nil }
        return parseSizeToken(trimmed)
    }

    // MARK: - Date parsing

    private static let dateTokenPattern =
        #"([0-9]{4}-[0-9]{2}-[0-9]{2}(?:[ T][0-9]{2}:[0-9]{2}(?::[0-9]{2})?)?|[0-9]{2}-[A-Za-z]{3}-[0-9]{4}(?: [0-9]{2}:[0-9]{2})?)"#

    private static let dateFormats = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd",
        "dd-MMM-yyyy HH:mm",
        "dd-MMM-yyyy"
    ]

    /// Extracts a date token from a cell or trailing row text.
    private static func parseDateToken(_ raw: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: dateTokenPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: raw) else { return nil }
        return parseDate(String(raw[tokenRange]))
    }

    /// Strict full-string date parser used by tests.
    public static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

/// Decides whether a fetched page is an open directory.
///
/// Deliberately permissive about empty directories: a parent-directory link,
/// an "Index of" marker, or a listing table proves a listing even when zero
/// items were parsed. A bare generic HTML page with no listing signals is
/// NOT a directory and should be handed to the Web Browser instead.
public enum DirectoryDetector {
    public static func isOpenDirectory(_ result: DirectoryParseResult, contentType: String?) -> Bool {
        guard result.isHTML else { return false }
        let mime = contentType?.lowercased() ?? ""
        if !mime.isEmpty, !mime.contains("text/html"), !mime.contains("text/plain") {
            return false
        }
        if result.hasParentLink || result.hasListingMarker || result.hasTable {
            return true
        }
        return result.directoryAnchorCount > 0 && result.anchorCount > 0
    }
}