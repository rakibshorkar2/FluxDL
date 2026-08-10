import SwiftUI
import WebKit
import Combine

@MainActor
public final class BrowserViewModel: ObservableObject {
    @Published public var inputURLText: String = ""
    @Published public var currentURL: URL? = URL(string: "https://google.com")
    @Published public var pageTitle: String = ""
    @Published public var isLoading: Bool = false
    @Published public var estimatedProgress: Double = 0.0
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    
    @Published public var detectedDownloadURL: URL? = nil
    @Published public var showDownloadPrompt: Bool = false
    @Published public var loadErrorMessage: String? = nil
    @Published public var isOffline: Bool = false
    @Published public var isChromeCollapsed: Bool = false
    @Published public var isAddressFieldFocused: Bool = false {
        didSet {
            if isAddressFieldFocused { isChromeCollapsed = false }
        }
    }
    @Published public var isClearHistoryPresented: Bool = false
    
    // Sub-view presentation flags
    @Published public var isBookmarksPresented: Bool = false
    @Published public var isHistoryPresented: Bool = false
    @Published public var isSettingsPresented: Bool = false
    @Published public var isFindInPagePresented: Bool = false
    
    @Published public var tabManager = BrowserTabManager.shared
    public let bookmarkManager = BookmarkManager.shared
    public let historyManager = BrowserHistoryManager.shared
    public let settings = BrowserSettings.shared
    public let findInPageManager = FindInPageManager()
    public let connectivityMonitor = BrowserConnectivityMonitor.shared
    public let proxySession = BrowserProxySession.shared
    public let hapticService: HapticServiceProtocol = ServiceContainer.shared.hapticService
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        tabManager.$activeTabId
            .sink { [weak self] _ in
                self?.syncActiveTabState()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: BrowserConnectivityMonitor.connectivityDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let isConnected = (note.userInfo?["isConnected"] as? Bool) ?? true
                self?.isOffline = !isConnected
                self?.syncActiveTabState()
                // Auto-reload the page when connectivity returns.
                if isConnected, let webView = self?.tabManager.activeTab?.webView,
                   self?.loadErrorMessage != nil {
                    self?.loadErrorMessage = nil
                    webView.reload()
                }
            }
            .store(in: &cancellables)
        
        syncActiveTabState()
    }
    
    public func syncActiveTabState() {
        guard let activeTab = tabManager.activeTab else { return }
        self.currentURL = activeTab.url
        self.inputURLText = activeTab.url?.absoluteString ?? activeTab.inputURLText
        self.pageTitle = activeTab.title
        self.isLoading = activeTab.isLoading
        self.estimatedProgress = activeTab.estimatedProgress
        self.canGoBack = activeTab.canGoBack
        self.canGoForward = activeTab.canGoForward
        self.isOffline = activeTab.isOffline || !connectivityMonitor.isConnected
        if self.isOffline && loadErrorMessage == nil {
            self.loadErrorMessage = "Your device appears to be offline."
        } else if !self.isOffline && loadErrorMessage == "Your device appears to be offline." {
            self.loadErrorMessage = nil
        }
    }
    
    public func handleSearchOrNavigate() {
        let trimmed = inputURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let targetURL: URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") {
            targetURL = URL(string: trimmed) ?? settings.searchEngine.searchURL(for: trimmed)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            targetURL = URL(string: "https://" + trimmed) ?? settings.searchEngine.searchURL(for: trimmed)
        } else {
            targetURL = settings.searchEngine.searchURL(for: trimmed)
        }
        
        currentURL = targetURL
        loadErrorMessage = nil
        if var activeTab = tabManager.activeTab {
            activeTab.url = targetURL
            activeTab.inputURLText = targetURL.absoluteString
            activeTab.isOffline = false
            tabManager.activeTab = activeTab
            activeTab.webView?.load(URLRequest(url: targetURL))
        }
    }
    
    public func goBack() {
        tabManager.activeTab?.webView?.goBack()
    }
    
    public func goForward() {
        tabManager.activeTab?.webView?.goForward()
    }
    
    public func reloadOrStop() {
        if isLoading {
            stopLoading()
        } else {
            loadErrorMessage = nil
            tabManager.activeTab?.webView?.reload()
        }
    }
    
    public func stopLoading() {
        tabManager.activeTab?.webView?.stopLoading()
        isLoading = false
        if var activeTab = tabManager.activeTab {
            activeTab.isLoading = false
            tabManager.activeTab = activeTab
        }
    }
    
    public func clearHistory() {
        historyManager.clearAllHistory()
        hapticService.impactOccurred(.light)
    }
    
    public func goHome() {
        if let homeURL = URL(string: settings.homepage) {
            inputURLText = homeURL.absoluteString
            handleSearchOrNavigate()
        }
    }
    
    public func toggleDesktopMode() {
        guard var activeTab = tabManager.activeTab else { return }
        activeTab.isDesktopMode.toggle()
        tabManager.activeTab = activeTab

        // Apply the UA change directly to the live WKWebView and reload once.
        // updateUIView must NOT do this — it fires on every SwiftUI render pass.
        if let webView = tabManager.activeTab?.webView {
            if activeTab.isDesktopMode {
                webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
            } else {
                webView.customUserAgent = nil
            }
            webView.reload()
        }
    }

    
    public func promptDownload(url: URL) {
        detectedDownloadURL = url
        showDownloadPrompt = true
    }
    
    public func startDetectedDownload() {
        guard let url = detectedDownloadURL else { return }
        _ = ServiceContainer.shared.downloadEngine.startDownload(url: url, filename: nil)
        showDownloadPrompt = false
        detectedDownloadURL = nil
    }
    
    public func toggleBookmarkCurrentPage() {
        guard let url = currentURL else { return }
        let urlStr = url.absoluteString
        if bookmarkManager.isBookmarked(urlString: urlStr) {
            if let item = bookmarkManager.bookmarks.first(where: { $0.urlString == urlStr }) {
                bookmarkManager.removeBookmark(id: item.id)
                hapticService.impactOccurred(.light)
            }
        } else {
            bookmarkManager.addBookmark(title: pageTitle.isEmpty ? urlStr : pageTitle, urlString: urlStr)
            hapticService.notificationOccurred(.success)
        }
    }
    
    public func copyCurrentURL() {
        guard let url = currentURL else { return }
        UIPasteboard.general.string = url.absoluteString
        hapticService.selectionChanged()
    }
    
    public func shareCurrentPage() {
        guard let url = currentURL else { return }
        ServiceContainer.shared.fileManagementService.shareFile(url: url, from: nil)
        hapticService.selectionChanged()
    }
    
    public func openInSafari() {
        guard let url = currentURL else { return }
        UIApplication.shared.open(url)
    }
    
    public func savePageAsPDF() {
        guard let webView = tabManager.activeTab?.webView else { return }
        let config = WKPDFConfiguration()
        webView.createPDF(configuration: config) { result in
            switch result {
            case .success(let data):
                let filename = (webView.title ?? "Page").appending(".pdf")
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? data.write(to: tempURL)
                Task { @MainActor in
                    _ = try? ServiceContainer.shared.fileManagementService.moveFile(from: tempURL, to: filename)
                }
            case .failure(let error):
                print("FluxDL: PDF generation error \(error.localizedDescription)")
            }
        }
    }
}
