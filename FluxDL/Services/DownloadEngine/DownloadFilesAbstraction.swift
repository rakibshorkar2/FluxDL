import Foundation

// MARK: - Files / Documents abstraction

/// Describes where downloaded files live and what the app can do with them
/// today, plus the abstraction layer for a future full File Provider
/// integration. Kept deliberately small: the app currently exposes files via
/// its own file list (Download tab) and can hand URLs to the system share
/// sheet / Quick Look. A real File Provider (Files app browsing, on-demand
/// materialization) would require a separate app-extension target — an
/// app-wide change outside this task's scope — so this abstraction documents
/// the interface instead of faking it.
public enum DownloadFilesAbstraction {

    /// Where completed downloads are stored on this device.
    public static func downloadsDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Verifies a completed file exists and is non-empty.
    public static func fileExists(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return (attributes[.size] as? Int64 ?? 0) > 0
    }

    /// Builds the full destination URL for a download, honoring folder-group
    /// relative paths when present.
    public static func destinationURL(
        baseDirectory: URL,
        filename: String,
        folderRelativePath: String?,
        fileManager: FileManager = .default
    ) -> URL {
        var destination = baseDirectory
        if let relative = folderRelativePath, !relative.isEmpty {
            destination = destination.appendingPathComponent(relative, isDirectory: true)
        }
        return destination.appendingPathComponent(filename)
    }

    /// List of files the system share/Quick Look can be offered.
    public static func shareableURL(for fileURL: URL) -> URL? {
        guard fileExists(at: fileURL) else { return nil }
        return fileURL
    }
}