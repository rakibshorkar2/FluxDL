import Foundation
import WebKit

public struct BrowserTabModel: Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var url: URL?
    public var inputURLText: String
    public var isLoading: Bool
    public var estimatedProgress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isDesktopMode: Bool
    public var isPrivate: Bool
    public var faviconURL: URL?
    public var lastActiveDate: Date
    public var isOffline: Bool = false
    
    // Lazy web view instance reference
    public var webView: WKWebView?
    
    // MARK: - Persistence snapshot
    
    /// Codable representation of a tab that can be stored/restored without a web view.
    public struct Snapshot: Codable, Equatable {
        public let id: UUID
        public let title: String
        public let urlString: String?
        public let inputURLText: String
        public let isDesktopMode: Bool
        public let isPrivate: Bool
        public let lastActiveDate: Date
        
        public var url: URL? {
            urlString.flatMap(URL.init(string:))
        }
    }
    
    public func snapshot() -> Snapshot {
        Snapshot(
            id: id,
            title: title,
            urlString: url?.absoluteString,
            inputURLText: inputURLText,
            isDesktopMode: isDesktopMode,
            isPrivate: isPrivate,
            lastActiveDate: lastActiveDate
        )
    }
    
    public init(snapshot: Snapshot) {
        self.id = snapshot.id
        self.title = snapshot.title
        self.url = snapshot.url
        self.inputURLText = snapshot.inputURLText
        self.isLoading = false
        self.estimatedProgress = 0.0
        self.canGoBack = false
        self.canGoForward = false
        self.isDesktopMode = snapshot.isDesktopMode
        self.isPrivate = snapshot.isPrivate
        self.faviconURL = nil
        self.lastActiveDate = snapshot.lastActiveDate
        self.webView = nil
    }
    
    public static func == (lhs: BrowserTabModel, rhs: BrowserTabModel) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.url == rhs.url &&
        lhs.isLoading == rhs.isLoading &&
        lhs.estimatedProgress == rhs.estimatedProgress &&
        lhs.canGoBack == rhs.canGoBack &&
        lhs.canGoForward == rhs.canGoForward &&
        lhs.isDesktopMode == rhs.isDesktopMode &&
        lhs.isPrivate == rhs.isPrivate &&
        lhs.isOffline == rhs.isOffline
    }
    
    public init(
        id: UUID = UUID(),
        title: String = "New Tab",
        url: URL? = URL(string: "https://google.com"),
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.inputURLText = url?.absoluteString ?? ""
        self.isLoading = false
        self.estimatedProgress = 0.0
        self.canGoBack = false
        self.canGoForward = false
        self.isDesktopMode = BrowserSettings.shared.requestDesktopByDefault
        self.isPrivate = isPrivate
        self.faviconURL = nil
        self.lastActiveDate = Date()
        self.webView = nil
    }
}
