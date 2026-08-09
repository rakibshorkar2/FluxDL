import Foundation
import UIKit
import Combine

public protocol ClipboardServiceProtocol: AnyObject {
    var detectedURLPublisher: AnyPublisher<URL?, Never> { get }
    func checkClipboardOnAppActive()
    func dismissDetectedURL()
}

public final class ClipboardService: ObservableObject, ClipboardServiceProtocol {
    @Published public private(set) var detectedURL: URL?
    
    public var detectedURLPublisher: AnyPublisher<URL?, Never> {
        $detectedURL.eraseToAnyPublisher()
    }
    
    private let supportedExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2",
        "mp4", "mkv", "avi", "mov", "webm", "flv",
        "mp3", "m4a", "flac", "wav", "aac",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "ipa", "apk", "exe", "dmg", "iso",
        "png", "jpg", "jpeg", "gif", "webp", "svg"
    ]
    
    private var lastCheckedString: String = ""
    
    public init() {}
    
    /// Event-driven clipboard check on app foreground — no battery-draining timer loop.
    public func checkClipboardOnAppActive() {
        guard UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings else { return }
        
        var targetURL: URL? = UIPasteboard.general.url
        if targetURL == nil, let string = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if string != lastCheckedString, (string.hasPrefix("http://") || string.hasPrefix("https://")), let url = URL(string: string) {
                targetURL = url
                lastCheckedString = string
            }
        }
        
        guard let url = targetURL else { return }
        let ext = url.pathExtension.lowercased()
        
        // Smart recognition by supported extension or direct media download link
        if supportedExtensions.contains(ext) || isLikelyDirectDownloadURL(url) {
            Task { @MainActor in
                self.detectedURL = url
            }
        }
    }
    
    public func dismissDetectedURL() {
        detectedURL = nil
    }
    
    private func isLikelyDirectDownloadURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/download") || path.contains("/get") || url.query?.contains("download") == true
    }
}
