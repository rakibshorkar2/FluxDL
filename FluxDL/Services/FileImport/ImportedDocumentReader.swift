import Foundation

/// User-facing import errors. Messages never expose internal filesystem
/// paths or document-provider URLs.
public enum ImportedDocumentError: LocalizedError, Equatable {
    /// The file does not exist or could not be reached.
    case fileUnavailable
    /// The file exists but its contents could not be read.
    case fileNotReadable
    /// The bytes could not be decoded as UTF-8 text.
    case invalidEncoding
    /// The file is not a document the importer accepts.
    case invalidDocument

    public var userMessage: String {
        switch self {
        case .fileUnavailable, .fileNotReadable:
            return "Could not open the selected file."
        case .invalidEncoding:
            return "The selected file could not be read as UTF-8 text."
        case .invalidDocument:
            return "The selected file is not a supported document."
        }
    }

    public var errorDescription: String? { userMessage }
}

/// Small helper that turns a picked document URL into a readable local file.
///
/// Responsibilities are limited to: obtaining a readable app-local copy,
/// validating existence/readability, reading bytes/text, and temporary-file
/// cleanup. It never parses YAML, never parses torrents and knows nothing
/// about proxies or the torrent engine.
///
/// Flow:
///
///     document provider URL
///             ↓
///     UIDocumentPicker (asCopy: true)
///             ↓
///     readableCopy(of:) — app-local URLs are used as-is; anything else is
///     copied into the app's temporary directory
///             ↓
///     existing YAML parser / TorrentService
///
/// The temporary copy is deleted by the caller via `removeTemporaryCopy`.
public final class ImportedDocumentReader {

    /// Subdirectory of the app's temporary directory holding defensive copies.
    public static let temporaryDirectoryName = "FluxDLImport"

    // MARK: - Copy resolution

    /// Returns a readable, app-local URL for the picked document.
    ///
    /// URLs already inside the app sandbox are returned as-is. Any other URL
    /// (document-provider, security-scoped, virtualized filesystem) is copied
    /// into `FileManager.default.temporaryDirectory/FluxDLImport` with a
    /// unique filename. Security-scoped access is started only to perform the
    /// copy and is always stopped afterwards; a failed
    /// `startAccessingSecurityScopedResource()` is not fatal — the URL is
    /// still probed for direct readability first.
    ///
    /// Callers must delete the result with `removeTemporaryCopy(at:)` when
    /// processing finishes. The user's original document is never touched.
    public static func readableCopy(
        of url: URL,
        preferredExtension: String? = nil
    ) -> Result<URL, ImportedDocumentError> {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileUnavailable)
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        // Already-readable app-local file: use it directly.
        if FileManager.default.isReadableFile(atPath: url.path), isAppLocal(url) {
            return .success(url)
        }

        // Everything else gets a defensive local copy.
        return copyToTemporaryDirectory(from: url, preferredExtension: preferredExtension)
    }

    /// Copies `url` into the app's temporary directory under a unique name.
    /// The original file is never modified or removed.
    public static func copyToTemporaryDirectory(
        from url: URL,
        preferredExtension: String? = nil
    ) -> Result<URL, ImportedDocumentError> {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(temporaryDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.fileUnavailable)
        }

        let ext = preferredExtension ?? url.pathExtension
        let target = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try fileManager.copyItem(at: url, to: target)
        } catch {
            return .failure(.fileUnavailable)
        }
        guard fileManager.isReadableFile(atPath: target.path) else {
            return .failure(.fileNotReadable)
        }
        return .success(target)
    }

    // MARK: - Reading

    /// Reads the raw bytes of a local file.
    public static func readData(from url: URL) -> Result<Data, ImportedDocumentError> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return .failure(.fileUnavailable)
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            return .failure(.fileNotReadable)
        }
        do {
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure(.fileNotReadable)
        }
    }

    /// Reads a local file as UTF-8 text, stripping a leading byte-order mark.
    public static func readText(from url: URL) -> Result<String, ImportedDocumentError> {
        switch readData(from: url) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard var text = String(data: data, encoding: .utf8) else {
                return .failure(.invalidEncoding)
            }
            if text.hasPrefix("\u{FEFF}") {
                text.removeFirst()
            }
            return .success(text)
        }
    }

    // MARK: - Cleanup

    /// Deletes a temporary copy produced by this reader. Safe to call with
    /// any URL; never touches the user's original document.
    public static func removeTemporaryCopy(at url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryDirectoryName, isDirectory: true)
        guard url.path.hasPrefix(directory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Best-effort removal of leftover copies from crashed/aborted imports.
    /// Called once at app launch.
    public static func cleanupStaleTemporaryCopies() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryDirectoryName, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Document classification

    /// Whether the URL looks like a YAML document (.yaml / .yml).
    public static func isYAMLDocument(_ url: URL) -> Bool {
        ["yaml", "yml"].contains(url.pathExtension.lowercased())
    }

    /// Whether the URL looks like a BitTorrent metadata file (.torrent).
    public static func isTorrentDocument(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "torrent"
    }

    /// Whether the URL lives inside this app's own sandbox.
    private static func isAppLocal(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(NSHomeDirectory())
    }
}