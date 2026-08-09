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
    
    // Lazy web view instance reference
    public var webView: WKWebView?
    
    public static func == (lhs: BrowserTabModel, rhs: BrowserTabModel) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.url == rhs.url &&
        lhs.isLoading == rhs.isLoading &&
        lhs.estimatedProgress == rhs.estimatedProgress &&
        lhs.canGoBack == rhs.canGoBack &&
        lhs.canGoForward == rhs.canGoForward &&
        lhs.isDesktopMode == rhs.isDesktopMode &&
        lhs.isPrivate == rhs.isPrivate
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
