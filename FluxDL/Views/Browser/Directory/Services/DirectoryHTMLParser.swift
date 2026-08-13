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
                // TEMP DEBUG (§23): remove before finalizing.
                print("FluxDL DirectoryParser: name=\(text) href=\(href) sizeBytes=\(size.map(String.init) ?? "nil") date=\(date.map(String.init) ?? "nil")")
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
    /// the date slot (layout-agnostic across 3/4/5-column variants).
    ///
    /// The anchor cell (the one holding the filename) is NEVER scanned for a
    /// size: filenames routinely contain digits ("A.Bugs.Life.1998.1080p…")
    /// that would otherwise be misread as byte counts. Only the text after
    /// `</a>` of that cell counts, for servers that append size/date there.
    /// Non-anchor cells are classified strictly (the whole cell must BE a
    /// size or a date) so combined cells fall through to a safe token scan.
    /// Nginx: the trailing text of the row after the anchor.
    private static func extractRowMetadata(ns: NSString, matchRange: NSRange) -> (Int64?, Date?) {
        let matchStart = matchRange.location
        if let (rowStart, rowEnd) = enclosingTableRow(ns: ns, anchorLocation: matchStart) {
            let row = ns.substring(with: NSRange(location: rowStart, length: rowEnd - rowStart))
            let cells = tableCells(in: row)
            if !cells.isEmpty {
                var size: Int64?
                var date: Date?
                var nonAnchorText = ""
                for cell in cells {
                    let stripped = String(
                        cell
                            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                            .replacingOccurrences(of: "&nbsp;", with: " ", options: [.caseInsensitive])
                            .replacingOccurrences(of: "&#160;", with: " ")
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    if cell.lowercased().contains("<a") {
                        guard let closeTagRange = cell.range(of: "</a>", options: .caseInsensitive) else { continue }
                        let suffix = String(cell[closeTagRange.upperBound...])
                            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if suffix.isEmpty { continue }
                        if date == nil, let parsed = parseDate(suffix) {
                            date = parsed
                        } else if size == nil, let parsed = parseSize(suffix) {
                            size = parsed
                        }
                    } else {
                        nonAnchorText += " " + stripped
                        if date == nil, let parsed = parseDate(stripped) {
                            date = parsed
                        } else if size == nil, let parsed = parseSize(stripped) {
                            size = parsed
                        }
                    }
                }
                if size != nil || date != nil {
                    // Strict cells already told us what this row carries.
                    // Never guess from leftover text (description columns can
                    // legitimately contain "Requires 4 GB…").
                    return (size, date)
                }
                // No cell is a clean size/date on its own — some servers cram
                // "1.48G 2025-04-12 10:14" into a single trailing cell.
                return extractTrailingMetadata(nonAnchorText)
            }
        }

        let afterAnchor = ns.substring(from: matchStart + matchRange.length)
        let lineEnd = (afterAnchor as NSString).range(of: "\n")
        let remainder = lineEnd.location == NSNotFound
            ? afterAnchor
            : (afterAnchor as NSString).substring(to: lineEnd.location)
        return extractTrailingMetadata(remainder)
    }

    private static func enclosingTableRow(ns: NSString, anchorLocation: Int) -> (Int, Int)? {
        let searchLength = min(anchorLocation, 40_000)
        let beforeStart = max(0, anchorLocation - searchLength)
        let before = ns.substring(with: NSRange(location: beforeStart, length: searchLength))
        let after = ns.substring(with: NSRange(location: anchorLocation, length: min(ns.length - anchorLocation, 20_000)))
        guard let openRegex = try? NSRegularExpression(pattern: #"<tr\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        let openMatches = openRegex.matches(
            in: before,
            options: [],
            range: NSRange(location: 0, length: (before as NSString).length)
        )
        guard let openMatch = openMatches.last else { return nil }
        let closeRange = (after as NSString).range(of: "</tr>")
        guard closeRange.location != NSNotFound else { return nil }
        return (beforeStart + openMatch.range.location, anchorLocation + closeRange.location + closeRange.length)
    }

    /// Size/date extraction from free text (Nginx rows, combined cells).
    ///
    /// The date span is consumed first and removed from the remainder so it
    /// can never be misread as a size ("2025" is a year, not a byte count).
    private static func extractTrailingMetadata(_ raw: String) -> (Int64?, Date?) {
        var remainder = raw
            .replacingOccurrences(of: "&nbsp;", with: " ", options: [.caseInsensitive])
            .replacingOccurrences(of: "&#160;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var date: Date?
        var size: Int64?
        if let hit = dateToken(in: remainder), let parsed = parseDate(hit.token) {
            date = parsed
            remainder = remainder
                .replacingCharacters(in: hit.fullRange, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parsed = extractSizeToken(from: remainder) {
            size = parsed
        }
        return (size, date)
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

    /// Strict: the entire trimmed string must be one size (e.g. "1.48G",
    /// "1,480 MB", "500 B", "5").
    private static let strictSizePattern = #"^((?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]+)?)\s*([KMGTP]?i?B?)$"#

    /// Lenient: finds a size token inside larger text, but ONLY when it
    /// carries an explicit unit suffix (K/M/G/T/P, optional i, optional B).
    /// Bare numbers are never matched here — filenames, years and ids are
    /// not sizes.
    private static let sizedTokenPattern = #"((?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]+)?)\s*([KMGTP]i?B)"#

    /// Converts a matched `(number, unit)` pair into a byte count.
    private static func sizeValue(from match: NSTextCheckingResult, in raw: String) -> Int64? {
        guard let numberRange = Range(match.range(at: 1), in: raw),
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
        case "P", "PB", "PIB": multiplier = 1024 * 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(value * multiplier)
    }

    /// Strict full-string size parser (table cells, tests).
    public static func parseSize(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        guard let regex = try? NSRegularExpression(pattern: strictSizePattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else { return nil }
        return sizeValue(from: match, in: trimmed)
    }

    /// Lenient size extraction from trailing row text: the whole remainder
    /// is tried strictly first, then a unit-bearing token is searched.
    private static func extractSizeToken(from raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let strict = parseSize(trimmed) { return strict }
        guard let regex = try? NSRegularExpression(pattern: sizedTokenPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else { return nil }
        return sizeValue(from: match, in: trimmed)
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

    /// First date token found in `raw`, plus the range of the whole matched
    /// span so callers can remove it from the remainder.
    private static func dateToken(in raw: String) -> (token: String, fullRange: Range<String.Index>)? {
        guard let regex = try? NSRegularExpression(pattern: dateTokenPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: raw),
              let fullRange = Range(match.range(at: 0), in: raw) else { return nil }
        return (String(raw[tokenRange]), fullRange)
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