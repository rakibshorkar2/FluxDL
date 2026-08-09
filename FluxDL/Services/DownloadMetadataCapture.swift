import Foundation
import UniformTypeIdentifiers

// MARK: - CapturedMetadata

/// A pure value type extracted from an HTTP response.
/// Computed nonisolated on the delegate queue and passed via Task { @MainActor }.
public struct CapturedMetadata: Sendable {
    public let httpStatusCode:    Int
    public let acceptsRanges:     Bool
    public let etag:              String?
    public let lastModified:      String?
    public let mimeType:          String?
    public let serverName:        String?
    public let redirectCount:     Int
    public let responseHeaders:   [String: String]

    // MIME helpers
    public var utType: UTType? {
        guard let mime = mimeType else { return nil }
        return UTType(mimeType: mime)
    }

    public var suggestedExtension: String? {
        utType?.preferredFilenameExtension
    }

    public var detectedCategory: String {
        guard let uti = utType else { return "Unknown" }
        if uti.conforms(to: .video)            { return "Video" }
        if uti.conforms(to: .audio)            { return "Audio" }
        if uti.conforms(to: .image)            { return "Image" }
        if uti.conforms(to: .pdf)              { return "PDF" }
        if uti.conforms(to: .archive)          { return "Archive" }
        if uti.conforms(to: .spreadsheet)      { return "Spreadsheet" }
        if uti.conforms(to: .presentation)     { return "Presentation" }
        if uti.conforms(to: .text)             { return "Text" }
        if uti.conforms(to: .sourceCode)       { return "Source Code" }
        return "Other"
    }
}

// MARK: - DownloadMetadataCapture

/// Nonisolated helper — safe to call from any thread, including the URLSession delegate queue.
public enum DownloadMetadataCapture {

    /// Safe subset of response headers to store (excludes credentials/cookies).
    private static let allowedHeaders: Set<String> = [
        "content-length",
        "accept-ranges",
        "content-disposition",
        "content-type",
        "cache-control",
        "etag",
        "last-modified",
        "server",
        "location",
        "x-content-duration",
        "transfer-encoding",
    ]

    /// Extract metadata from a URLResponse. Returns nil for non-HTTP responses.
    public static func capture(from response: URLResponse?, task: URLSessionTask? = nil) -> CapturedMetadata? {
        guard let httpResp = response as? HTTPURLResponse else { return nil }

        // Build normalised header dict (lowercase keys, safe subset)
        var headers: [String: String] = [:]
        for (key, value) in httpResp.allHeaderFields {
            let k = "\(key)".lowercased()
            if allowedHeaders.contains(k) {
                headers[k] = "\(value)"
            }
        }

        let acceptsRanges = headers["accept-ranges"]?.lowercased() == "bytes"
        let etag          = headers["etag"]
        let lastModified  = headers["last-modified"]
        let server        = headers["server"]
        let mimeType: String? = {
            guard let ct = headers["content-type"] else { return nil }
            // Strip charset/boundary parameters
            return ct.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
        }()

        // URLSessionTask doesn't expose redirect count directly; we track it separately.
        // For now, default to 0; DownloadEngine can increment via willPerformHTTPRedirection.
        let redirectCount = 0

        return CapturedMetadata(
            httpStatusCode:  httpResp.statusCode,
            acceptsRanges:   acceptsRanges,
            etag:            etag,
            lastModified:    lastModified,
            mimeType:        mimeType,
            serverName:      server,
            redirectCount:   redirectCount,
            responseHeaders: headers
        )
    }
}
