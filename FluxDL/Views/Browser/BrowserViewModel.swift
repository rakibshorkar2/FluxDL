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

/// The exact, uniquely-identified download request that triggered the
/// "Download File?" popup. Every pending request carries its own UUID so the
/// popup can never show stale state from an earlier tap.
public struct BrowserDownloadRequest: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let filename: String?
    public let mimeType: String?
    public let fileSize: Int64?
    public let sourceURL: URL?

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String? = nil,
        mimeType: String? = nil,
        fileSize: Int64? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.sourceURL = sourceURL
    }

    /// Best available filename for the popup: exact request metadata first,
    /// then a safe derivation from Content-Disposition / URL path / MIME.
    public var displayFilename: String {
        if let filename, !filename.isEmpty { return filename }
        return URLFilenameExtractor.extractFilename(from: url, contentDisposition: nil)
    }
}

/// The exact, uniquely-identified torrent request behind the "Add Torrent?"
/// popup. Carries the metadata extracted for display and a fresh UUID so the
/// popup never shows stale state from an earlier link.
public struct BrowserTorrentPrompt: Identifiable, Equatable {
    public enum Kind: Equatable {
        case magnet
        case remoteTorrent
    }

    public let id: UUID
    public let url: URL
    public let kind: Kind
    /// User-facing name: the magnet `dn=` value (or fallback), the remote
    /// file's name, or a sensible default. Never the raw magnet URI.
    public let displayName: String
    /// The `xt=urn:btih:` hash for magnet links, when present.
    public let infoHash: String?
    /// Number of `tr=` trackers for magnet links.
    public let trackerCount: Int

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: Kind,
        displayName: String,
        infoHash: String? = nil,
        trackerCount: Int = 0
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.displayName = displayName
        self.infoHash = infoHash
        self.trackerCount = trackerCount
    }

    /// Short label shown in the popup's "Type" row.
    public var kindLabel: String {
        switch kind {
        case .magnet: return "Magnet Link"
        case .remoteTorrent: return "Remote torrent file"
        }
    }
}

/// Extractors for `javascript:` URLs. The scheme prefix is stripped and the
/// source is percent-decoded exactly once — arbitrary JavaScript (containing
/// `%`, `+`, quotes, parentheses, semicolons, etc.) is never re-decoded.
public enum BrowserJavaScript {
    public static let scheme = "javascript:"

    public static func script(fromJavaScriptURLString input: String) -> String? {
        guard input.lowercased().hasPrefix(scheme) else { return nil }
        let schemeEnd = input.index(input.startIndex, offsetBy: scheme.count)
        let raw = String(input[schemeEnd...])
        guard !raw.isEmpty else { return nil }
        return raw.removingPercentEncoding ?? raw
    }

    public static func script(fromJavaScriptURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "javascript" else { return nil }
        return script(fromJavaScriptURLString: url.absoluteString)
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

    /// Whether the Browser tab shows the web browser or the open-directory
    /// browser. Both worlds keep their full state; switching never destroys
    /// the active tab's WKWebView.
    @Published public var browserMode: BrowserMode = .web

    /// Mode switch callback used by the "Open in Web Browser" fallback —
    /// hands the URL to the existing web navigation path.
    public func openInWebBrowser(_ url: URL) {
        browserMode = .web
        inputURLText = url.absoluteString
        handleSearchOrNavigate()
    }

    /// Convenience mirror of `pendingDownload` for the pre-existing API surface.
    public var detectedDownloadURL: URL? {
        get { pendingDownload?.url }
        set { pendingDownload = newValue.map { BrowserDownloadRequest(url: $0) } }
    }
    @Published public var pendingDownload: BrowserDownloadRequest? = nil
    @Published public var showDownloadPrompt: Bool = false
    /// The exact torrent request behind the "Add Torrent?" popup. A fresh ID
    /// per request; the same URL is deduplicated while visible so the JS
    /// bridge and the navigation delegate never double-present the same tap.
    @Published public var torrentPrompt: BrowserTorrentPrompt? = nil
    @Published public var showTorrentPrompt: Bool = false
    /// True while a remote `.torrent` file is being fetched/validated.
    @Published public var isTorrentPromptLoading: Bool = false
    /// User-facing error from a failed add/fetch, shown inside the popup.
    @Published public var torrentPromptErrorMessage: String? = nil
    /// Guards against duplicate submissions while an add is in flight.
    public private(set) var torrentPromptSubmissionInFlight = false
    /// Global (window) coordinates of the element that triggered the pending
    /// download — nil when the trigger was programmatic (no DOM element).
    @Published public var downloadAnchorPoint: CGPoint? = nil
    /// Document-space coordinates of the element, used to re-anchor the popup
    /// as the page scrolls under it.
    @Published public var downloadAnchorPagePoint: CGPoint? = nil
    /// User-facing message for `javascript:` execution failures / disabled JS.
    @Published public var javascriptExecutionMessage: String? = nil
    /// Global origin of the Browser chrome, used to convert anchor coordinates
    /// from window space into SwiftUI local space.
    public var browserWindowOrigin: CGPoint = .zero
    /// Injectable loader for remote `.torrent` metadata. The default performs
    /// a plain URLSession GET; tests swap this to serve canned data without
    /// touching the network.
    public var remoteTorrentDataLoader: (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "The server returned an error (HTTP \(http.statusCode))."]
            )
        }
        return data
    }
    @Published public var loadErrorMessage: String? = nil
    @Published public var isOffline: Bool = false
    @Published public var isAddressFieldFocused: Bool = false {
        didSet {
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
    /// Proxy configuration fingerprint of the last tab reload, so profile
    /// switches (which fire `proxyDidChange` without flipping the route)
    /// trigger exactly one reload per effective configuration.
    private var lastReloadedProxyFingerprint: String?
    
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

        // When the effective proxy route changes, reload every tab that has
        // loaded a page so content is fetched under the new route (or direct
        // mode). `proxyDidChange` covers both flips (enable/disable/toggle)
        // and configuration swaps — profile switches while the proxy stays
        // active never flip `isProxyActive`, so they are deduplicated by
        // fingerprint and reloaded too.
        proxySession.proxyDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let fingerprint = self.proxySession.activeConfiguration?.fingerprint
                guard fingerprint != self.lastReloadedProxyFingerprint else { return }
                self.lastReloadedProxyFingerprint = fingerprint
                for tab in self.tabManager.tabs where tab.webView?.url != nil {
                    tab.webView?.reload()
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
        isAddressFieldFocused = false
        
        // `javascript:` URLs execute against the currently loaded page.
        // They must never hit the search engine, the URL bar state, history,
        // or webView.load().
        if let script = BrowserJavaScript.script(fromJavaScriptURLString: trimmed) {
            executeJavaScript(script)
            return
        }
        
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
    
    /// Runs JavaScript against the active tab's `WKWebView` without navigating,
    /// without touching `currentURL` and without touching browsing history.
    ///
    /// `BrowserSettings.isJavaScriptEnabled` stays authoritative: when disabled,
    /// execution is rejected with a user-facing message and navigation is untouched.
    @discardableResult
    public func executeJavaScript(_ script: String) -> Bool {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        guard settings.isJavaScriptEnabled else {
            javascriptExecutionMessage = "JavaScript is disabled. Turn on JavaScript in Browser Settings to run it."
            return false
        }
        
        guard let webView = tabManager.activeTab?.webView else {
            javascriptExecutionMessage = "There is no loaded page to run JavaScript on."
            return false
        }
        
        webView.evaluateJavaScript(trimmed) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    #if DEBUG
                    print("FluxDL: evaluateJavaScript failed — \(error.localizedDescription)")
                    #endif
                    self.javascriptExecutionMessage = "JavaScript could not be executed: \(error.localizedDescription)"
                }
            }
        }
        return true
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
        promptDownload(url: url, filename: nil, mimeType: nil, fileSize: nil, sourceURL: nil, anchorPoint: nil, anchorPagePoint: nil)
    }
    
    /// Registers the exact download request that triggered the popup. Unique
    /// per request; a newer request replaces an older visible one
    /// deterministically, but the same URL is deduplicated so the JS bridge
    /// and the navigation delegate don't double-present the same tap.
    public func promptDownload(
        url: URL,
        filename: String? = nil,
        mimeType: String? = nil,
        fileSize: Int64? = nil,
        sourceURL: URL? = nil,
        anchorPoint: CGPoint? = nil,
        anchorPagePoint: CGPoint? = nil
    ) {
        // `javascript:` commands must never be treated as downloadable files.
        guard url.scheme?.lowercased() != "javascript" else { return }
        // Torrent links (magnet URIs, `.torrent` URLs) belong to the torrent
        // flow. Even if a path bypasses the navigation interception, they must
        // never reach the generic DownloadEngine.
        guard !BrowserTorrentLink.isTorrent(url) else { return }
        
        let request = BrowserDownloadRequest(
            url: url,
            filename: filename,
            mimeType: mimeType,
            fileSize: fileSize,
            sourceURL: sourceURL ?? tabManager.activeTab?.url
        )
        presentDownloadPrompt(request, anchorPoint: anchorPoint, anchorPagePoint: anchorPagePoint)
    }
    
    private func presentDownloadPrompt(
        _ request: BrowserDownloadRequest,
        anchorPoint: CGPoint? = nil,
        anchorPagePoint: CGPoint? = nil
    ) {
        if showDownloadPrompt, pendingDownload?.url == request.url {
            // Same request already visible (JS bridge + delegate both detect the
            // same tap). Upgrade it with an anchor if one just arrived.
            if anchorPoint != nil, downloadAnchorPoint == nil {
                downloadAnchorPoint = anchorPoint
                downloadAnchorPagePoint = anchorPagePoint
            }
            return
        }
        pendingDownload = request
        downloadAnchorPoint = anchorPoint
        downloadAnchorPagePoint = anchorPagePoint
        showDownloadPrompt = true
    }
    
    public func startDetectedDownload() {
        guard let request = pendingDownload else { return }
        _ = ServiceContainer.shared.downloadEngine.startDownload(url: request.url, filename: request.filename)
        dismissDownloadPrompt()
    }
    
    public func cancelDetectedDownload() {
        dismissDownloadPrompt()
    }
    
    private func dismissDownloadPrompt() {
        showDownloadPrompt = false
        pendingDownload = nil
        downloadAnchorPoint = nil
        downloadAnchorPagePoint = nil
    }
    
    // MARK: - Torrent links (magnet / remote .torrent)
    
    /// Presents the "Add Torrent?" popup for a magnet URI or a remote
    /// `.torrent` link (also triggered by an `application/x-bittorrent`
    /// response via `mimeType`). Never routed through the DownloadEngine.
    public func promptTorrent(url: URL, filename: String? = nil, mimeType: String? = nil) {
        guard url.scheme?.lowercased() != "javascript" else { return }
        guard BrowserTorrentLink.isTorrent(url) || mimeType?.lowercased() == "application/x-bittorrent" else { return }
        
        let kind: BrowserTorrentPrompt.Kind = BrowserTorrentLink.isMagnet(url) ? .magnet : .remoteTorrent
        let displayName: String
        if kind == .magnet {
            let dn = BrowserTorrentLink.displayName(from: url)
            displayName = dn
                ?? BrowserTorrentLink.infoHash(from: url).map { "Torrent \($0.prefix(12))" }
                ?? "Magnet Link"
        } else {
            let fallback = URLFilenameExtractor.extractFilename(from: url, contentDisposition: nil)
            displayName = filename ?? (fallback.isEmpty ? "Torrent" : fallback)
        }
        let prompt = BrowserTorrentPrompt(
            url: url,
            kind: kind,
            displayName: displayName,
            infoHash: BrowserTorrentLink.infoHash(from: url),
            trackerCount: BrowserTorrentLink.trackerCount(in: url)
        )
        presentTorrentPrompt(prompt)
    }
    
    private func presentTorrentPrompt(_ prompt: BrowserTorrentPrompt) {
        if showTorrentPrompt, torrentPrompt?.url == prompt.url {
            // Same link already visible (JS bridge + delegate both detect the
            // same tap). Never stack a second popup.
            return
        }
        torrentPrompt = prompt
        showTorrentPrompt = true
        torrentPromptErrorMessage = nil
        isTorrentPromptLoading = false
        torrentPromptSubmissionInFlight = false
    }
    
    /// Starts the confirmed torrent add: magnets go straight to
    /// `TorrentService.addMagnet`; remote `.torrent` URLs are fetched,
    /// validated and added via `TorrentService.addTorrentFile(data:)`.
    /// Errors (including duplicate detection) surface inside the popup.
    public func startTorrentAddition() {
        guard let prompt = torrentPrompt, !torrentPromptSubmissionInFlight else { return }
        torrentPromptSubmissionInFlight = true
        torrentPromptErrorMessage = nil
        
        let service = ServiceContainer.shared.torrentService
        
        switch prompt.kind {
        case .magnet:
            if !service.isSessionActive {
                service.startSession()
            }
            let result = service.addMagnet(prompt.url.absoluteString)
            finishTorrentAddition(with: result)
        case .remoteTorrent:
            isTorrentPromptLoading = true
            Task { [weak self] in
                do {
                    let data = try await self?.remoteTorrentDataLoader(prompt.url)
                    guard let self, let data else { return }
                    if !service.isSessionActive {
                        service.startSession()
                    }
                    let result = service.addTorrentFile(data: data)
                    self.finishTorrentAddition(with: result)
                } catch {
                    guard let self else { return }
                    self.torrentPromptErrorMessage = Self.torrentLoadMessage(for: error)
                    self.isTorrentPromptLoading = false
                    self.torrentPromptSubmissionInFlight = false
                }
            }
        }
    }
    
    private func finishTorrentAddition(with result: Result<Void, TorrentServiceError>) {
        switch result {
        case .success:
            dismissTorrentPrompt()
        case .failure(let error):
            torrentPromptErrorMessage = error.localizedDescription
            isTorrentPromptLoading = false
            torrentPromptSubmissionInFlight = false
        }
    }
    
    /// Cancels the popup and clears ALL pending torrent state — a later add
    /// can never observe stale data from this request.
    public func cancelTorrentPrompt() {
        dismissTorrentPrompt()
    }
    
    private func dismissTorrentPrompt() {
        torrentPrompt = nil
        showTorrentPrompt = false
        isTorrentPromptLoading = false
        torrentPromptErrorMessage = nil
        torrentPromptSubmissionInFlight = false
    }
    
    /// Human-readable message for remote-metadata fetch failures.
    private static func torrentLoadMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection. Check your network and try again."
            case .timedOut:
                return "The connection to the server timed out."
            default:
                if let description = urlError.userInfo[NSLocalizedDescriptionKey] as? String,
                   !description.isEmpty {
                    return description
                }
            }
        }
        return error.localizedDescription
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
