import UIKit
import QuickLook

public protocol FileManagementServiceProtocol: AnyObject {
    var downloadsDirectoryURL: URL { get }
    func destinationURL(for filename: String) -> URL
    func moveFile(from tempURL: URL, to filename: String) throws -> URL
    /// Root directory for a folder download group (Downloads/<folderName>/).
    func folderDestinationURL(for folderName: String) -> URL
    /// Destination for a relative path (e.g. "Extras/Trailer.mp4") inside a
    /// folder directory, creating intermediate directories as needed.
    func destinationURL(forRelativePath relativePath: String, inDirectory directoryURL: URL) -> URL
    /// Moves a completed file to its relative path inside a folder directory.
    func moveFile(from tempURL: URL, toRelativePath relativePath: String, inDirectory directoryURL: URL) throws -> URL
    /// Removes a folder download's directory tree, but only when the path is
    /// safely contained inside the app's Downloads directory.
    func removeFolderDownloadDirectory(at url: URL)
    func fileExists(at url: URL) -> Bool
    func deleteFile(at url: URL) throws
    func shareFile(url: URL, from viewController: UIViewController?)
}

public final class FileManagementService: FileManagementServiceProtocol {
    private let fileManager = FileManager.default
    private let smartRoutingKey = "fluxdl_smart_routing"
    
    private var isSmartRoutingEnabled: Bool {
        UserDefaults.standard.object(forKey: smartRoutingKey) != nil
            ? UserDefaults.standard.bool(forKey: smartRoutingKey) : true
    }
    
    public var downloadsDirectoryURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
        if !fileManager.fileExists(atPath: downloads.path) {
            try? fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        }
        return downloads
    }
    
    public init() {}
    
    public func targetCategoryFolder(for filename: String) -> URL {
        guard isSmartRoutingEnabled else { return downloadsDirectoryURL }
        
        let ext = (filename as NSString).pathExtension.lowercased()
        let subfolderName: String
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "flv": subfolderName = "Videos"
        case "mp3", "m4a", "wav", "flac", "aac": subfolderName = "Music"
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt": subfolderName = "Documents"
        case "zip", "rar", "7z", "tar", "gz": subfolderName = "Archives"
        case "ipa", "apk", "exe", "dmg": subfolderName = "Apps"
        default: subfolderName = "Others"
        }
        
        let target = downloadsDirectoryURL.appendingPathComponent(subfolderName, isDirectory: true)
        if !fileManager.fileExists(atPath: target.path) {
            try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        return target
    }
    
    public func destinationURL(for filename: String) -> URL {
        let folder = targetCategoryFolder(for: filename)
        var targetURL = folder.appendingPathComponent(filename)
        var count = 1
        let nameWithoutExt = targetURL.deletingPathExtension().lastPathComponent
        let ext = targetURL.pathExtension
        
        while fileManager.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(nameWithoutExt)_\(count)" : "\(nameWithoutExt)_\(count).\(ext)"
            targetURL = folder.appendingPathComponent(newName)
            count += 1
        }
        return targetURL
    }
    
    public func moveFile(from tempURL: URL, to filename: String) throws -> URL {
        let destURL = destinationURL(for: filename)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    // MARK: Folder download destinations

    /// Root directory of a folder download group. Never subject to smart
    /// routing — the folder hierarchy must be preserved verbatim.
    public func folderDestinationURL(for folderName: String) -> URL {
        downloadsDirectoryURL.appendingPathComponent(
            Self.sanitizedPathComponent(folderName),
            isDirectory: true
        )
    }

    /// Resolves the destination for a relative path (e.g. "Extras/Trailer.mp4")
    /// inside a folder directory, creating intermediate directories. Every
    /// component is sanitized so "..", "/" and empty segments can never
    /// escape the folder root.
    public func destinationURL(forRelativePath relativePath: String, inDirectory directoryURL: URL) -> URL {
        let components = relativePath
            .split(separator: "/")
            .map(String.init)
            .map(Self.sanitizedPathComponent)
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return directoryURL }

        let parent = components.dropLast().reduce(directoryURL) { url, component in
            let dir = url.appendingPathComponent(component, isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        let lastComponent = components.last ?? ""
        var targetURL = parent.appendingPathComponent(lastComponent)

        // Collision handling — mirrors destinationURL(for:).
        let nameWithoutExt = targetURL.deletingPathExtension().lastPathComponent
        let ext = targetURL.pathExtension
        var count = 1
        while fileManager.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(nameWithoutExt)_\(count)" : "\(nameWithoutExt)_\(count).\(ext)"
            targetURL = parent.appendingPathComponent(newName)
            count += 1
        }
        return targetURL
    }

    /// Moves a completed download into its relative path inside the folder
    /// directory, preserving the server-side hierarchy.
    public func moveFile(from tempURL: URL, toRelativePath relativePath: String, inDirectory directoryURL: URL) throws -> URL {
        let destURL = destinationURL(forRelativePath: relativePath, inDirectory: directoryURL)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    /// Deletes a folder download's directory tree. Fail-closed: the path
    /// must live inside the app's Downloads directory or nothing happens.
    public func removeFolderDownloadDirectory(at url: URL) {
        let root = downloadsDirectoryURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(root + "/"),
              fileManager.fileExists(atPath: target) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Sanitizes a single path component for filesystem use: separators and
    /// control characters are replaced, "." / ".." collapse to a safe token,
    /// and absurd lengths are clipped. Display naming is untouched — this
    /// only affects storage paths.
    public static func sanitizedPathComponent(_ raw: String) -> String {
        var component = raw.components(separatedBy: CharacterSet(charactersIn: "/\u{0}\n\r\t:")).joined(separator: "_")
        component = component.trimmingCharacters(in: .whitespacesAndNewlines)
        if component.isEmpty || component == "." || component == ".." {
            component = "_"
        }
        if component.count > 150 {
            component = String(component.prefix(150))
        }
        return component
    }
    
    public func fileExists(at url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }
    
    public func deleteFile(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
    
    @MainActor
    public func shareFile(url: URL, from viewController: UIViewController? = nil) {
        // Non-local or missing URLs (e.g. sharing a web page) fall back to
        // sharing the URL itself instead of silently doing nothing.
        let activityItems: [Any] = fileExists(at: url) ? [url] : [url.absoluteString]
        let activityVC = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        
        if let topController = viewController ?? UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first {
            
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topController.view
                popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            topController.present(activityVC, animated: true)
        }
    }
}
