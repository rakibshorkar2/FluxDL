import SwiftUI
import WebKit
import Combine

/// A single address-bar autocomplete suggestion, sourced from bookmarks or history.
public struct URLSuggestion: Identifiable, Equatable {
    public enum Kind: Equatable {
        case bookmark
        case history
    }

    public let id: UUID
    public let title: String
    public let urlString: String
    public let kind: Kind

    public var url: URL? { URL(string: urlString) }

    public init(id: UUID = UUID(), title: String, urlString: String, kind: Kind) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.kind = kind
    }
}

@MainActor
public final class BrowserViewModel: ObservableObject {
    @Published public var inputURLText: String = "" {
        didSet { updateSuggestions() }
    }
    @Published public var currentURL: URL? = URL(string: "https://google.com")
    @Published public var pageTitle: String = ""
    @Published public var isLoading: Bool = false
    @Published public var estimatedProgress: Double = 0.0
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var blockedRequestCount: Int = 0
    @Published public var suggestions: [URLSuggestion] = []
    @Published public var isReaderMode: Bool = false

    @Published public var detectedDownloadURL: URL? = nil
    @Published public var showDownloadPrompt: Bool = false
    @Published public var loadErrorMessage: String? = nil
    @Published public var isOffline: Bool = false
    @Published public var isChromeCollapsed: Bool = false
    @Published public var isAddressFieldFocused: Bool = false {
        didSet {
            if isAddressFieldFocused { isChromeCollapsed = false }
            if !isAddressFieldFocused { suggestions = [] }
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

        // Keep the blocked-request badge in sync while the page loads.
        NotificationCenter.default.publisher(for: AdBlockEngine.blockedRequestCountDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let host = note.userInfo?["host"] as? String,
                      self.tabManager.activeTab?.url?.host == host else { return }
                self.blockedRequestCount = AdBlockEngine.shared.blockedCount(forHost: host)
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
        self.isReaderMode = activeTab.isReaderMode
        self.blockedRequestCount = AdBlockEngine.shared.blockedCount(forHost: activeTab.url?.host)
        if self.isOffline && loadErrorMessage == nil {
            self.loadErrorMessage = "Your device appears to be offline."
        } else if !self.isOffline && loadErrorMessage == "Your device appears to be offline." {
            self.loadErrorMessage = nil
        }
    }
    
    public func handleSearchOrNavigate() {
        let trimmed = inputURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        suggestions = []
        
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

    // MARK: - Address-bar suggestions

    /// Recomputes the autocomplete suggestions from bookmarks + history.
    /// Prefix matches rank first; results are capped and deduplicated by URL.
    private func updateSuggestions() {
        let query = inputURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              query.lowercased() != (currentURL?.absoluteString ?? "").lowercased() else {
            suggestions = []
            return
        }

        let lowerQuery = query.lowercased()
        var results: [URLSuggestion] = []
        var seen = Set<String>()

        func add(_ title: String, _ urlString: String, _ kind: URLSuggestion.Kind) {
            let key = urlString.lowercased()
            guard seen.insert(key).inserted else { return }
            results.append(URLSuggestion(title: title, urlString: urlString, kind: kind))
        }

        func matchesPrefix(_ candidate: String) -> Bool {
            candidate.lowercased().hasPrefix(lowerQuery)
        }

        let bookmarks = bookmarkManager.bookmarks
        let history = historyManager.historyItems

        // First pass: prefix matches (bookmarks take priority over history).
        for item in bookmarks where results.count < 8 && (matchesPrefix(item.title) || matchesPrefix(item.urlString)) {
            add(item.title, item.urlString, .bookmark)
        }
        for item in history where results.count < 8 && (matchesPrefix(item.title) || matchesPrefix(item.urlString)) {
            add(item.title, item.urlString, .history)
        }
        // Second pass: substring matches.
        for item in bookmarks where results.count < 8 &&
            (item.title.localizedCaseInsensitiveContains(query) || item.urlString.localizedCaseInsensitiveContains(query)) {
            add(item.title, item.urlString, .bookmark)
        }
        for item in history where results.count < 8 &&
            (item.title.localizedCaseInsensitiveContains(query) || item.urlString.localizedCaseInsensitiveContains(query)) {
            add(item.title, item.urlString, .history)
        }

        suggestions = Array(results.prefix(8))
    }

    public func selectSuggestion(_ suggestion: URLSuggestion) {
        inputURLText = suggestion.urlString
        suggestions = []
        isAddressFieldFocused = false
        hapticService.selectionChanged()
        handleSearchOrNavigate()
    }

    public func dismissSuggestions() {
        suggestions = []
    }

    // MARK: - Private browsing

    public func createPrivateTab() {
        _ = tabManager.createNewTab(isPrivate: true)
        hapticService.selectionChanged()
    }

    // MARK: - Reader Mode

    public func toggleReaderMode() {
        guard let webView = tabManager.activeTab?.webView,
              var activeTab = tabManager.activeTab else { return }
        activeTab.isReaderMode.toggle()
        tabManager.activeTab = activeTab
        isReaderMode = activeTab.isReaderMode
        hapticService.selectionChanged()
        if activeTab.isReaderMode {
            webView.evaluateJavaScript(ReaderModeScript.applySource, completionHandler: nil)
        } else {
            // Exiting restores the original page.
            webView.reload()
        }
    }

    // MARK: - Keyboard

    /// Resigns first responder and collapses the chrome + suggestions.
    public func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isAddressFieldFocused = false
        suggestions = []
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
