import Foundation

/// Pure, testable classification of torrent links for the Browser tab.
///
/// Two link kinds are recognized:
///   • magnet URIs (`magnet:?xt=urn:btih:...`) — never sent to WebKit and
///     never routed through the generic DownloadEngine.
///   • remote `.torrent` files (URLs whose path ends in `.torrent`). A server
///     identifying a response as `application/x-bittorrent` is detected by the
///     navigation-response handler at runtime (it cannot be derived from the
///     URL alone).
public enum BrowserTorrentLink {

    /// True when `url` is either a magnet link or a remote `.torrent` URL.
    public static func isTorrent(_ url: URL) -> Bool {
        isMagnet(url) || isRemoteTorrent(url)
    }

    /// True for `magnet:` URIs (e.g. `magnet:?xt=urn:btih:<40 hex>&dn=...`).
    public static func isMagnet(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "magnet" else { return false }
        return !url.absoluteString.isEmpty
    }

    /// True for http(s) URLs whose path extension is `torrent`.
    public static func isRemoteTorrent(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return url.pathExtension.lowercased() == "torrent"
    }

    // MARK: - Magnet metadata extraction (display only)

    /// The `dn=` display name from a magnet link, percent-decoded.
    public static func displayName(from url: URL) -> String? {
        guard let query = url.query else { return nil }
        for item in queryComponents(query) where item.key == "dn" {
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The v1 info hash from the magnet's `xt=urn:btih:` parameter.
    public static func infoHash(from url: URL) -> String? {
        guard let query = url.query else { return nil }
        for item in queryComponents(query) where item.key == "xt" {
            let value = item.value.lowercased()
            if value.hasPrefix("urn:btih:") {
                let hash = String(value.dropFirst("urn:btih:".count))
                if !hash.isEmpty { return hash }
            }
        }
        return nil
    }

    /// Number of `tr=` tracker parameters in the magnet link.
    public static func trackerCount(in url: URL) -> Int {
        guard let query = url.query else { return 0 }
        return queryComponents(query).reduce(0) { $0 + ($1.key == "tr" ? 1 : 0) }
    }

    // MARK: - Query parsing

    /// Splits a raw query string into percent-decoded key/value pairs.
    /// Deliberately independent of `URLComponents` (which can fail on some
    /// magnet URIs) and tolerant of repeated keys.
    private static func queryComponents(_ query: String) -> [(key: String, value: String)] {
        query.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let rawKey = parts.first, !rawKey.isEmpty else { return nil }
            let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let value = (rawValue.removingPercentEncoding ?? rawValue)
                .replacingOccurrences(of: "+", with: " ")
            return (key, value)
        }
    }
}
