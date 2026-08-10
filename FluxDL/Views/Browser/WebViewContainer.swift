import SwiftUI
import WebKit
import Combine

/// Passive JS bridge that reports the DOM element behind a tapped download
/// link. WebKit's navigation callbacks never expose the element's CGRect, so
/// the click listener captures href / download-attribute / bounding rect and
/// posts them to Swift for popup anchoring. It never modifies page behavior.
public enum DownloadBridgeScript {
    public static let messageName = "downloadTrigger"

    public static let source = """
    (function () {
        if (window.__fluxdlDownloadBridgeInstalled) { return; }
        window.__fluxdlDownloadBridgeInstalled = true;
        document.addEventListener("click", function (event) {
            var el = event.target;
            if (!el) { return; }
            var anchor = null;
            if (typeof el.closest === "function") {
                anchor = el.closest("a[href]");
            }
            if (!anchor && el.tagName && String(el.tagName).toLowerCase() === "a" && el.href) {
                anchor = el;
            }
            if (!anchor) { return; }
            var href = anchor.getAttribute("href");
            if (!href || href.toLowerCase().indexOf("javascript:") === 0) { return; }
            var rect = anchor.getBoundingClientRect();
            var message = {
                href: anchor.href || href,
                download: anchor.getAttribute("download") || "",
                hasDownload: anchor.hasAttribute("download"),
                x: rect.left + rect.width / 2,
                y: rect.top + rect.height / 2,
                scrollX: window.pageXOffset || document.documentElement.scrollLeft || 0,
                scrollY: window.pageYOffset || document.documentElement.scrollTop || 0
            };
            try {
                window.webkit.messageHandlers.downloadTrigger.postMessage(message);
            } catch (err) {}
        }, true);
    })();
    """
}

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

        // Download-trigger bridge: captures the DOM element behind a tapped
        // downloadable link so the "Download File?" popup can be anchored to it.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: DownloadBridgeScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

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
        applyWebpageAppearance(to: webView)
        
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

        applyWebpageAppearance(to: uiView)

        // Only update the findInPage web-view reference when the WKWebView instance itself changes.
        if context.coordinator.observedWebView !== uiView {
            viewModel.findInPageManager.setWebView(uiView)
        }
    }

    // MARK: - Webpage appearance

    /// Applies the user's webpage appearance preference. `.system` follows
    /// the OS appearance, `.light`/`.dark` force the interface style, and
    /// `.automatic` leaves the color-scheme to each website so its own
    /// native dark theme (per `prefers-color-scheme`) is used.
    private func applyWebpageAppearance(to webView: WKWebView) {
        switch BrowserSettings.shared.webpageAppearance {
        case .system:
            webView.overrideUserInterfaceStyle = .unspecified
        case .light:
            webView.overrideUserInterfaceStyle = .light
        case .dark:
            webView.overrideUserInterfaceStyle = .dark
        case .automatic:
            webView.overrideUserInterfaceStyle = .unspecified
        }
    }
    
    // MARK: - Coordinator
    
    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        var viewModel: BrowserViewModel
        weak var observedWebView: WKWebView?
        private var lastScrollOffsetY: CGFloat = 0
        private var isDragging = false
        private var cancellables = Set<AnyCancellable>()
        
        /// File extensions that trigger the "Download File?" popup.
        static let downloadableExtensions: Set<String> = [
            "zip", "rar", "7z", "ipa", "dmg", "pkg", "pdf", "mp4", "mkv",
            "avi", "mp3", "aac", "flac", "png", "jpg", "gif", "webp", "docx",
            "xlsx", "pptx", "iso", "apk", "exe"
        ]
        
        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }
        
        func attachObservers(to webView: WKWebView) {
            detachObservers()
            self.observedWebView = webView
            webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
            webView.configuration.userContentController.add(
                self,
                name: DownloadBridgeScript.messageName
            )
            
            // Live webpage-appearance updates while a page is open: when the
            // user changes the "Webpage Appearance" setting the visible page's
            // `prefers-color-scheme` environment is updated without a reload.
            BrowserSettings.shared.$webpageAppearance
                .receive(on: DispatchQueue.main)
                .sink { [weak webView, weak self] _ in
                    if let webView, let self {
                        self.applyWebpageAppearance(to: webView)
                    }
                }
                .store(in: &cancellables)
        }
        
        func detachObservers() {
            if let webView = observedWebView {
                webView.removeObserver(self, forKeyPath: "estimatedProgress")
                webView.removeObserver(self, forKeyPath: "title")
                webView.removeObserver(self, forKeyPath: "URL")
                webView.scrollView.delegate = nil
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: DownloadBridgeScript.messageName
                )
                self.observedWebView = nil
            }
            cancellables.removeAll()
        }
        
        /// Maps the Browser "Webpage Appearance" setting onto WKWebView so the
        /// page receives the matching `prefers-color-scheme` environment.
        /// `.system` / `.automatic` follow the OS appearance; `.light` / `.dark`
        /// force the preference. No CSS inversion is ever applied.
        private func applyWebpageAppearance(to webView: WKWebView) {
            switch BrowserSettings.shared.webpageAppearance {
            case .system, .automatic:
                if webView.overrideUserInterfaceStyle != .unspecified {
                    webView.overrideUserInterfaceStyle = .unspecified
                }
            case .light:
                if webView.overrideUserInterfaceStyle != .light {
                    webView.overrideUserInterfaceStyle = .light
                }
            case .dark:
                if webView.overrideUserInterfaceStyle != .dark {
                    webView.overrideUserInterfaceStyle = .dark
                }
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
            // Keep the "Download File?" popup attached to its triggering element
            // while the page scrolls beneath it.
            if self.viewModel.showDownloadPrompt,
               let pagePoint = self.viewModel.downloadAnchorPagePoint,
               let webView = observedWebView {
                let viewPoint = CGPoint(
                    x: pagePoint.x - scrollView.contentOffset.x,
                    y: pagePoint.y - scrollView.contentOffset.y
                )
                self.viewModel.downloadAnchorPoint = webView.convert(viewPoint, to: nil)
            }
            
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
                // `javascript:` links (e.g. <a href="javascript:...">) execute
                // against the current page instead of navigating. This runs
                // before any download detection so a `javascript:` URL can never
                // be treated as a downloadable file.
                if url.scheme?.lowercased() == "javascript",
                   let script = BrowserJavaScript.script(fromJavaScriptURL: url) {
                    decisionHandler(.cancel)
                    Task { @MainActor in
                        self.viewModel.executeJavaScript(script)
                    }
                    return
                }

                let ext = url.pathExtension.lowercased()
                if Self.downloadableExtensions.contains(ext) {
                    Task { @MainActor in
                        self.viewModel.promptDownload(url: url, sourceURL: webView.url)
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
               let responseURL = response.url,
               responseURL.scheme?.lowercased() != "javascript",
               let mimeType = response.mimeType?.lowercased() {
                
                let downloadableMimeTypes = [
                    "application/zip", "application/x-rar-compressed", "application/x-7z-compressed",
                    "application/octet-stream", "video/mp4", "video/x-matroska", "audio/mpeg",
                    "application/pdf", "application/vnd.android.package-archive"
                ]
                
                if downloadableMimeTypes.contains(mimeType) {
                    // Capture Content-Disposition / Content-Length when available
                    // so the popup shows the exact requested file.
                    let contentDisposition = response.allHeaderFields["Content-Disposition"] as? String
                    let filename = contentDisposition.flatMap {
                        URLFilenameExtractor.extractFilename(fromContentDisposition: $0)
                    }
                    let expectedLength = response.expectedContentLength
                    let fileSize: Int64? = expectedLength >= 0 ? expectedLength : nil
                    
                    Task { @MainActor in
                        self.viewModel.promptDownload(
                            url: responseURL,
                            filename: filename,
                            mimeType: response.mimeType,
                            fileSize: fileSize,
                            sourceURL: webView.url
                        )
                    }
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        // MARK: - Download-trigger bridge (WKScriptMessageHandler)
        
        /// Receives the DOM element behind a tapped downloadable link. This is
        /// the only reliable way to anchor the "Download File?" popup to the
        /// exact control the user tapped — WKNavigationDelegate callbacks never
        /// expose element coordinates.
        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == DownloadBridgeScript.messageName,
                  let payload = message.body as? [String: Any],
                  let href = payload["href"] as? String,
                  let url = URL(string: href),
                  url.scheme?.lowercased() != "javascript",
                  let webView = observedWebView else { return }
            
            // Only surface genuine download triggers: an explicit `download`
            // attribute or a known downloadable extension.
            let downloadAttribute = (payload["download"] as? String) ?? ""
            let hasDownloadAttribute = (payload["hasDownload"] as? Bool) == true
                || !downloadAttribute.isEmpty
            let ext = url.pathExtension.lowercased()
            guard hasDownloadAttribute || Self.downloadableExtensions.contains(ext) else { return }
            
            // `<a download="filename">`: the attribute value is the requested name.
            let filename = !downloadAttribute.isEmpty
                ? (downloadAttribute.removingPercentEncoding ?? downloadAttribute)
                : nil
            
            guard let rawX = payload["x"] as? Double,
                  let rawY = payload["y"] as? Double,
                  let scrollX = payload["scrollX"] as? Double,
                  let scrollY = payload["scrollY"] as? Double else {
                Task { @MainActor in
                    self.viewModel.promptDownload(url: url, filename: filename, sourceURL: webView.url)
                }
                return
            }
            
            // CSS pixels -> UIKit points. Accomodates pinch zoom; the bridge
            // reports viewport-relative rects, so document-space coordinates
            // are reconstructed for scroll-following.
            let zoom = webView.scrollView.zoomScale
            let viewPoint = CGPoint(x: rawX * zoom, y: rawY * zoom)
            let globalPoint = webView.convert(viewPoint, to: nil)
            let pagePoint = CGPoint(x: rawX + scrollX, y: rawY + scrollY)
            
            Task { @MainActor in
                self.viewModel.promptDownload(
                    url: url,
                    filename: filename,
                    sourceURL: webView.url,
                    anchorPoint: globalPoint,
                    anchorPagePoint: pagePoint
                )
            }
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
