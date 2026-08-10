import SwiftUI
import WebKit

/// JavaScript used by Reader Mode. Extracts the main article content and
/// presents it in a clean reading view. Exiting reader mode reloads the page.
public enum ReaderModeScript {
    public static let applySource = """
    (function () {
        if (document.documentElement.getAttribute("data-fluxdl-reader") === "1") { return; }
        function score(el) {
            var paragraphs = el.querySelectorAll("p").length;
            var length = (el.innerText || "").length;
            return paragraphs * 4 + Math.min(length / 300, 25);
        }
        var candidates = [];
        var selectors = ["article", "main", '[role="main"]', ".article", ".post", ".entry-content", ".content"];
        var found = document.querySelectorAll(selectors.join(","));
        for (var i = 0; i < found.length; i++) { candidates.push(found[i]); }
        var divs = document.querySelectorAll("body div");
        for (var i = 0; i < divs.length && i < 400; i++) {
            if (divs[i].querySelectorAll("p").length >= 3) { candidates.push(divs[i]); }
        }
        var best = null, bestScore = 8;
        for (var i = 0; i < candidates.length; i++) {
            var s = score(candidates[i]);
            if (s > bestScore) { bestScore = s; best = candidates[i]; }
        }
        if (!best) { return; }
        var clone = best.cloneNode(true);
        var remove = clone.querySelectorAll("script,style,noscript,iframe,nav,aside,form,button,.ad,.ads,.advert,.advertisement,.banner,.social,.share,.comments,.related,.promo,.footer,.header,.sidebar,[class*='advert'],[id*='advert']");
        for (var i = 0; i < remove.length; i++) {
            if (remove[i].parentNode) { remove[i].parentNode.removeChild(remove[i]); }
        }
        var links = clone.querySelectorAll("a");
        for (var i = 0; i < links.length; i++) {
            var plain = document.createTextNode(links[i].innerText || "");
            if (links[i].parentNode) { links[i].parentNode.replaceChild(plain, links[i]); }
        }
        var images = clone.querySelectorAll("img");
        for (var i = 0; i < images.length; i++) {
            if (!images[i].getAttribute("src")) { images[i].removeAttribute("src"); }
        }
        var container = document.createElement("div");
        container.id = "fluxdl-reader-container";
        container.appendChild(clone);
        var style = document.createElement("style");
        style.id = "fluxdl-reader-style";
        style.textContent = "#fluxdl-reader-container{max-width:46rem;margin:0 auto;padding:2.5rem 1.5rem;line-height:1.7;font-size:1.05rem;color:#1a1a1a;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;}" +
            "#fluxdl-reader-container h1,h2,h3{line-height:1.3;margin:1.2em 0 0.5em;}" +
            "#fluxdl-reader-container p{margin:0 0 1em;}" +
            "#fluxdl-reader-container img{max-width:100%;height:auto;border-radius:8px;}" +
            "#fluxdl-reader-container a{color:#0a66c2;}" +
            "@media (prefers-color-scheme:dark){#fluxdl-reader-container{color:#e8e8e8;}}";
        document.body.innerHTML = "";
        document.body.appendChild(style);
        document.body.appendChild(container);
        document.documentElement.setAttribute("data-fluxdl-reader", "1");
    })();
    """
}

public struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: BrowserViewModel
    
    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }
    
    public func makeUIView(context: Context) -> WKWebView {
        let activeTab = viewModel.tabManager.activeTab
        
        if let existingWebView = activeTab?.webView {
            existingWebView.navigationDelegate = context.coordinator
            existingWebView.uiDelegate = context.coordinator
            context.coordinator.attachObservers(to: existingWebView)
            return existingWebView
        }
        
        let configuration = WKWebViewConfiguration()
        configuration.processPool = viewModel.tabManager.sharedProcessPool
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Private tabs use an in-memory, non-persistent data store so all
        // cookies/cache die with the web view — nothing touches disk.
        if activeTab?.isPrivate == true {
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }

        // Apply native Ad Blocker rules
        AdBlockEngine.shared.applyRuleList(to: configuration, domain: activeTab?.url?.host)

        // Install the passive request-counting script alongside the rule list
        // so the UI can surface a per-page blocked-request badge.
        if AdBlockEngine.shared.shouldApplyProtection(domain: activeTab?.url?.host) {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: AdBlockEngine.countingScriptSource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
            configuration.userContentController.add(
                AdBlockEngine.shared.blockedRequestHandler,
                name: AdBlockEngine.counterScriptMessageName
            )
        }
        
        // Configure preferences
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = BrowserSettings.shared.isJavaScriptEnabled
        configuration.defaultWebpagePreferences = preferences
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !BrowserSettings.shared.isPopupBlockingEnabled
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.delegate = context.coordinator
        
        if let isDesktop = activeTab?.isDesktopMode, isDesktop {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        }
        
        viewModel.tabManager.activeTab?.webView = webView
        viewModel.findInPageManager.setWebView(webView)
        context.coordinator.attachObservers(to: webView)
        
        if let initialURL = viewModel.currentURL {
            webView.load(URLRequest(url: initialURL))
        }
        
        return webView
    }
    
    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // Only update custom UA; never auto-reload here.
        // updateUIView is called on every SwiftUI render — triggering reload() here
        // would re-load the page on every progress tick or title change.
        let activeTab = viewModel.tabManager.activeTab
        let expectedUA: String? = (activeTab?.isDesktopMode ?? false)
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
            : nil

        if uiView.customUserAgent != expectedUA {
            uiView.customUserAgent = expectedUA
        }

        // Only update the findInPage web-view reference when the WKWebView instance itself changes.
        if context.coordinator.observedWebView !== uiView {
            viewModel.findInPageManager.setWebView(uiView)
        }
    }
    
    // MARK: - Coordinator
    
    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate {
        var viewModel: BrowserViewModel
        weak var observedWebView: WKWebView?
        private var lastScrollOffsetY: CGFloat = 0
        private var isDragging = false
        
        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }
        
        func attachObservers(to webView: WKWebView) {
            detachObservers()
            self.observedWebView = webView
            webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
        }
        
        func detachObservers() {
            if let webView = observedWebView {
                webView.removeObserver(self, forKeyPath: "estimatedProgress")
                webView.removeObserver(self, forKeyPath: "title")
                webView.removeObserver(self, forKeyPath: "URL")
                webView.scrollView.delegate = nil
                self.observedWebView = nil
            }
        }
        
        public override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey : Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard let webView = observedWebView else { return }
            Task { @MainActor in
                if keyPath == "estimatedProgress" {
                    self.viewModel.estimatedProgress = webView.estimatedProgress
                    if var activeTab = self.viewModel.tabManager.activeTab {
                        activeTab.estimatedProgress = webView.estimatedProgress
                        self.viewModel.tabManager.activeTab = activeTab
                    }
                } else if keyPath == "title" {
                    let title = webView.title ?? ""
                    self.viewModel.pageTitle = title
                    if var activeTab = self.viewModel.tabManager.activeTab, !title.isEmpty {
                        activeTab.title = title
                        self.viewModel.tabManager.activeTab = activeTab
                    }
                } else if keyPath == "URL" {
                    if let url = webView.url {
                        self.viewModel.currentURL = url
                        self.viewModel.inputURLText = url.absoluteString
                        self.viewModel.canGoBack = webView.canGoBack
                        self.viewModel.canGoForward = webView.canGoForward
                        
                        if var activeTab = self.viewModel.tabManager.activeTab {
                            activeTab.url = url
                            activeTab.inputURLText = url.absoluteString
                            activeTab.canGoBack = webView.canGoBack
                            activeTab.canGoForward = webView.canGoForward
                            if url.scheme == "https" || url.scheme == "http" {
                                activeTab.faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(url.host ?? "")&sz=64")
                            }
                            self.viewModel.tabManager.activeTab = activeTab
                        }
                    }
                }
            }
        }
        
        // MARK: - Toolbar scroll collapse (UIScrollViewDelegate)
        
        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isDragging = true
            lastScrollOffsetY = scrollView.contentOffset.y
            // Dismiss the keyboard + suggestions when the user scrolls the page.
            if viewModel.isAddressFieldFocused {
                viewModel.dismissKeyboard()
            }
        }
        
        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isDragging, !viewModel.isAddressFieldFocused else { return }
            let y = scrollView.contentOffset.y
            let isScrollingDown = y > lastScrollOffsetY
            lastScrollOffsetY = y
            
            // Collapse the top chrome when scrolling down past a threshold;
            // expand again when nearing the top of the page.
            let collapsed = viewModel.isChromeCollapsed
            if isScrollingDown && y > 64 && !collapsed {
                viewModel.isChromeCollapsed = true
            } else if !isScrollingDown && y < 24 && collapsed {
                viewModel.isChromeCollapsed = false
            }
        }
        
        public func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            isDragging = false
        }
        
        // MARK: - WKNavigationDelegate
        
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Haptic feedback for swipe/chevron back-forward navigation.
            if navigationAction.navigationType == .backForward {
                Task { @MainActor in
                    self.viewModel.hapticService.impactOccurred(.light)
                }
            }

            if let url = navigationAction.request.url {
                let ext = url.pathExtension.lowercased()
                let downloadableExtensions = [
                    "zip", "rar", "7z", "ipa", "dmg", "pkg", "pdf", "mp4", "mkv",
                    "avi", "mp3", "aac", "flac", "png", "jpg", "gif", "webp", "docx",
                    "xlsx", "pptx", "iso", "apk", "exe"
                ]
                
                if downloadableExtensions.contains(ext) {
                    Task { @MainActor in
                        self.viewModel.promptDownload(url: url)
                    }
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let response = navigationResponse.response as? HTTPURLResponse,
               let mimeType = response.mimeType?.lowercased() {
                
                let downloadableMimeTypes = [
                    "application/zip", "application/x-rar-compressed", "application/x-7z-compressed",
                    "application/octet-stream", "video/mp4", "video/x-matroska", "audio/mpeg",
                    "application/pdf", "application/vnd.android.package-archive"
                ]
                
                if downloadableMimeTypes.contains(mimeType),
                   let url = response.url {
                    Task { @MainActor in
                        self.viewModel.promptDownload(url: url)
                    }
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                self.viewModel.isLoading = true
                self.viewModel.loadErrorMessage = nil
                self.viewModel.blockedRequestCount = 0
                if let host = webView.url?.host {
                    AdBlockEngine.shared.resetCount(forHost: host)
                }
                if var activeTab = self.viewModel.tabManager.activeTab {
                    activeTab.isLoading = true
                    activeTab.isOffline = false
                    activeTab.isReaderMode = false
                    self.viewModel.tabManager.activeTab = activeTab
                }
                self.viewModel.isReaderMode = false
            }
        }
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.viewModel.isLoading = false
                self.viewModel.loadErrorMessage = nil
                if var activeTab = self.viewModel.tabManager.activeTab {
                    activeTab.isLoading = false
                    activeTab.isOffline = false
                    self.viewModel.tabManager.activeTab = activeTab
                }
                // Incognito tabs never write to browsing history.
                let isPrivate = self.viewModel.tabManager.activeTab?.isPrivate ?? false
                if !isPrivate, let url = webView.url {
                    BrowserHistoryManager.shared.addHistory(
                        title: webView.title ?? url.host ?? url.absoluteString,
                        urlString: url.absoluteString
                    )
                }
            }
        }
        
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                self.viewModel.isLoading = false
                if var activeTab = self.viewModel.tabManager.activeTab {
                    activeTab.isLoading = false
                    self.viewModel.tabManager.activeTab = activeTab
                }
                self.setLoadError(error)
            }
        }
        
        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            Task { @MainActor in
                self.viewModel.isLoading = false
                if var activeTab = self.viewModel.tabManager.activeTab {
                    activeTab.isLoading = false
                    activeTab.isOffline = (error as NSError).code == NSURLErrorNotConnectedToInternet
                    self.viewModel.tabManager.activeTab = activeTab
                }
                self.setLoadError(error)
            }
        }
        
        @MainActor
        private func setLoadError(_ error: Error) {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                viewModel.loadErrorMessage = "No internet connection. Check your network and try again."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                viewModel.loadErrorMessage = "The server for this page could not be found."
            case NSURLErrorTimedOut:
                viewModel.loadErrorMessage = "The connection to the server timed out."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
                viewModel.loadErrorMessage = "The connection couldn't be secured (SSL error)."
            case NSURLErrorUnsupportedURL:
                viewModel.loadErrorMessage = "This URL type isn't supported."
            default:
                viewModel.loadErrorMessage = error.localizedDescription
            }
        }
        
        // MARK: - Popup Windows (WKUIDelegate)
        
        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            
            // Popup blocking: refuse to create the window entirely (returning
            // nil makes window.open() fail instead of opening a new tab).
            if BrowserSettings.shared.isPopupBlockingEnabled {
                BrowserTabManager.shared.hapticService.selectionChanged()
                return nil
            }
            
            // Popups open in a new tab, inheriting the parent tab's privacy state.
            Task { @MainActor in
                let isPrivate = self.viewModel.tabManager.activeTab?.isPrivate ?? false
                _ = BrowserTabManager.shared.createNewTab(url: url, isPrivate: isPrivate)
            }
            return nil
        }
        
        public func webViewDidClose(_ webView: WKWebView) {
            Task { @MainActor in
                BrowserTabManager.shared.closeTab(webView: webView)
            }
        }
        
        // MARK: - JavaScript Dialogs (WKUIDelegate)
        
        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let controller = UIAlertController(title: webView.title ?? "Message", message: message, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(controller)
        }
        
        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let controller = UIAlertController(title: webView.title ?? "Message", message: message, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            controller.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(controller)
        }
        
        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let controller = UIAlertController(title: webView.title ?? "Message", message: prompt, preferredStyle: .alert)
            controller.addTextField { $0.text = defaultText }
            controller.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            controller.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(controller.textFields?.first?.text)
            })
            present(controller)
        }
        
        private func present(_ controller: UIAlertController) {
            Task { @MainActor in
                guard let root = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                    .first?.rootViewController else { return }
                var presenter = root
                while let presented = presenter.presentedViewController {
                    presenter = presented
                }
                presenter.present(controller, animated: true)
            }
        }
        
        // MARK: - Context Menu Integration
        
        public func webView(
            _ webView: WKWebView,
            contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
            completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
        ) {
            let targetURL = elementInfo.linkURL

            let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                // Light haptic as the long-press link menu appears.
                Task { @MainActor in
                    self?.viewModel.hapticService.selectionChanged()
                }

                var actions: [UIAction] = []

                if let url = targetURL {
                    let openNewTabAction = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square")) { _ in
                        Task { @MainActor in
                            _ = BrowserTabManager.shared.createNewTab(url: url)
                        }
                    }
                    let openPrivateTabAction = UIAction(title: "Open in Private Tab", image: UIImage(systemName: "eye.slash")) { _ in
                        Task { @MainActor in
                            _ = BrowserTabManager.shared.createNewTab(url: url, isPrivate: true)
                        }
                    }
                    let copyLinkAction = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = url.absoluteString
                    }
                    let downloadAction = UIAction(title: "Download Link", image: UIImage(systemName: "arrow.down.circle")) { _ in
                        Task { @MainActor in
                            self?.viewModel.promptDownload(url: url)
                        }
                    }
                    let shareAction = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                        Task { @MainActor in
                            ServiceContainer.shared.fileManagementService.shareFile(url: url, from: nil)
                        }
                    }
                    actions.append(contentsOf: [openNewTabAction, openPrivateTabAction, copyLinkAction, downloadAction, shareAction])
                }
                return UIMenu(title: targetURL?.host ?? "", children: actions)
            }
            completionHandler(config)
        }
        
        deinit {
            detachObservers()
        }
    }
}
