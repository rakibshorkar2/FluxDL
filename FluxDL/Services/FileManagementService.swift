import UIKit
import QuickLook

public protocol FileManagementServiceProtocol: AnyObject {
    var downloadsDirectoryURL: URL { get }
    func destinationURL(for filename: String) -> URL
    func moveFile(from tempURL: URL, to filename: String) throws -> URL
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
        guard fileExists(at: url) else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
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
