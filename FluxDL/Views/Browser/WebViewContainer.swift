import SwiftUI
import WebKit
import Combine

// MARK: - Networking reality (WKWebView + proxy)
//
// WKWebView does NOT route page-load traffic through URLSession proxy
// configuration. There is no legitimate, non-VPN API to tunnel the
// WKWebView's own networking. Page loads therefore always use the device's
// normal network path.
//
// What the browser proxy DOES cover (via `BrowserProxySession` and
// `ProxySessionProvider` — the same authoritative path the download engine
// uses) is the app-level URLSession traffic the browser layer creates:
// favicon fetching (`BrowserFaviconView`) and share/PDF plumbing. That
// traffic uses `sessionConfiguration()` which is proxied (strict no-failover)
// when Proxy Service is enabled AND browser routing is on, and is a plain
// ephemeral configuration (direct connection) otherwise.
//
// No VPN and no system-wide proxy are installed, and no other app or
// subsystem (including Torrent) is affected.

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

/// The desktop-mode user agent applied on demand.
public enum DesktopUserAgent {
    public static let string = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
}

/// A `UIViewRepresentable` hosting exactly ONE tab's WKWebView.
///
/// The representable (and its `Coordinator`) are permanently bound to one
/// immutable `tabID`. Every WebKit callback routed through the coordinator
/// mutates ONLY the `BrowserTabModel` owning that tabID — never
/// `tabManager.activeTab` directly. View-model-level ("active tab") state is
/// updated only when the bound tab happens to be the currently active tab,
/// so a background tab's web view can never corrupt the visible tab.
public struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: BrowserViewModel
    /// The exact tab this container renders. Immutable for the lifetime of
    /// the container — switching tabs recreates the container via `.id()`.
    let tabID: UUID
    
    public init(viewModel: BrowserViewModel, tabID: UUID) {
        self.viewModel = viewModel
        self.tabID = tabID
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, tabID: tabID)
    }
    
    public func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let tab = viewModel.tabManager.tab(for: tabID)
        
        // Reuse the bound tab's existing web view — never resolve the target
        // from `activeTab`, and never attach another tab's web view here.
        if let tab, let existingWebView = tab.webView {
            existingWebView.navigationDelegate = coordinator
            existingWebView.uiDelegate = coordinator
            // The previous coordinator nils the scroll delegate when
            // detaching; the reused web view must be re-assigned or the page
            // will never report scroll state (download-prompt anchoring).
            existingWebView.scrollView.delegate = coordinator
            coordinator.attachObservers(to: existingWebView)
            // Re-binding the find-in-page target on reuse: the manager may
            // still point at the previously active tab's web view.
            if tabID == viewModel.tabManager.activeTabId {
                viewModel.findInPageManager.setWebView(existingWebView)
            }
            return existingWebView
        }
        
        let configuration = WKWebViewConfiguration()
        configuration.processPool = viewModel.tabManager.sharedProcessPool
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Private tabs use an in-memory, non-persistent data store so all
        // cookies/cache die with the web view — nothing touches disk.
        if tab?.isPrivate == true {
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }

        // Apply native Ad Blocker rules
        AdBlockEngine.shared.applyRuleList(to: configuration, domain: tab?.url?.host)

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
        if AdBlockEngine.shared.shouldApplyProtection(domain: tab?.url?.host) {
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
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.delegate = coordinator
        applyWebpageAppearance(to: webView)
        
        if let tab, tab.isDesktopMode {
            webView.customUserAgent = DesktopUserAgent.string
        }
        
        // Store the web view on the EXACT bound tab — never on activeTab.
        viewModel.tabManager.updateTab(id: tabID) { $0.webView = webView }
        if tabID == viewModel.tabManager.activeTabId {
            viewModel.findInPageManager.setWebView(webView)
        }
        coordinator.attachObservers(to: webView)
        
        if let initialURL = tab?.url {
            webView.load(URLRequest(url: initialURL))
        }
        
        return webView
    }
    
    public func updateUIView(_ uiView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        
        // If the coordinator is not (or no longer) attached to the view it is
        // being asked to update, re-attach. This covers edge cases where the
        // bound tab's web view was replaced while a container was in flight.
        if coordinator.observedWebView !== uiView {
            coordinator.attachObservers(to: uiView)
            if tabID == viewModel.tabManager.activeTabId {
                viewModel.findInPageManager.setWebView(uiView)
            }
        }
        
        // Only update custom UA; never auto-reload here.
        // updateUIView is called on every SwiftUI render — triggering reload() here
        // would re-load the page on every progress tick or title change.
        let tab = viewModel.tabManager.tab(for: tabID)
        let expectedUA: String? = (tab?.isDesktopMode ?? false)
            ? DesktopUserAgent.string
            : nil

        if uiView.customUserAgent != expectedUA {
            uiView.customUserAgent = expectedUA
        }

        applyWebpageAppearance(to: uiView)
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
        /// The immutable tab this coordinator serves. Every callback is
        /// attributed to this tab; the coordinator NEVER reads
        /// `tabManager.activeTab` to decide which tab to mutate.
        let tabID: UUID
        /// Strong reference: guarantees the observed web view stays alive
        /// until this coordinator detaches, so KVO observers are always
        /// removed from a live object (never from a deallocated one).
        /// `fileprivate` so the container can verify the coordinator is
        /// attached to the view it is updating.
        fileprivate var observedWebView: WKWebView?
        private var cancellables = Set<AnyCancellable>()
        
        /// File extensions that trigger the "Download File?" popup.
        static let downloadableExtensions: Set<String> = [
            "zip", "rar", "7z", "ipa", "dmg", "pkg", "pdf", "mp4", "mkv",
            "avi", "mp3", "aac", "flac", "png", "jpg", "gif", "webp", "docx",
            "xlsx", "pptx", "iso", "apk", "exe"
        ]
        
        init(viewModel: BrowserViewModel, tabID: UUID) {
            self.viewModel = viewModel
            self.tabID = tabID
        }
        
        /// Whether this coordinator's tab is currently the visible tab. Only
        /// then may callbacks touch view-model ("active tab") UI state.
        private var boundTabIsActive: Bool {
            tabID == viewModel.tabManager.activeTabId
        }
        
        /// Mutates exactly the bound tab (no-op after the tab was closed).
        private func mutateBoundTab(_ mutate: (inout BrowserTabModel) -> Void) {
            viewModel.tabManager.updateTab(id: tabID, mutate)
        }
        
        func attachObservers(to webView: WKWebView) {
            if observedWebView === webView { return }
            detachObservers()
            self.observedWebView = webView
            webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
            webView.configuration.userContentController.add(
                self,
                name: DownloadBridgeScript.messageName
            )
            
            // The page may have navigated while this coordinator was detached
            // (background tabs keep loading without a delegate). Re-read the
            // web view's CURRENT state so the bound tab never shows stale
            // title/URL/back-forward state after a tab switch.
            syncBoundTab(from: webView)
            
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
        
        /// Pulls the bound tab's browsing state from the web view's current
        /// values. Mirrors into view-model ("active tab") state only when this
        /// tab is the visible one.
        private func syncBoundTab(from webView: WKWebView) {
            mutateBoundTab { tab in
                if let url = webView.url {
                    tab.url = url
                    tab.inputURLText = url.absoluteString
                    if url.scheme == "https" || url.scheme == "http" {
                        tab.faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(url.host ?? "")&sz=64")
                    }
                }
                if let title = webView.title, !title.isEmpty {
                    tab.title = title
                }
                tab.estimatedProgress = webView.estimatedProgress
                tab.canGoBack = webView.canGoBack
                tab.canGoForward = webView.canGoForward
                tab.isLoading = webView.isLoading
            }
            guard boundTabIsActive else { return }
            if let url = webView.url {
                viewModel.currentURL = url
                viewModel.inputURLText = url.absoluteString
                viewModel.canGoBack = webView.canGoBack
                viewModel.canGoForward = webView.canGoForward
            }
            if let title = webView.title, !title.isEmpty {
                viewModel.pageTitle = title
            }
            viewModel.estimatedProgress = webView.estimatedProgress
            viewModel.isLoading = webView.isLoading
        }
        
        /// Detaches this coordinator from its web view exactly once.
        ///
        /// KVO observers are per-observer, so removing our own registrations
        /// can never remove another coordinator's. The scroll delegate and the
        /// download-bridge message handler are only released when this
        /// coordinator is still the web view's owner (or the web view has no
        /// owner at all), so a late-detaching coordinator can never steal
        /// them from a successor.
        func detachObservers() {
            guard let webView = observedWebView else {
                cancellables.removeAll()
                return
            }
            webView.removeObserver(self, forKeyPath: "estimatedProgress")
            webView.removeObserver(self, forKeyPath: "title")
            webView.removeObserver(self, forKeyPath: "URL")
            if webView.scrollView.delegate === self || webView.navigationDelegate == nil {
                webView.scrollView.delegate = nil
            }
            if webView.navigationDelegate === self || webView.navigationDelegate == nil {
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: DownloadBridgeScript.messageName
                )
            }
            self.observedWebView = nil
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
            guard keyPath == "estimatedProgress" || keyPath == "title" || keyPath == "URL" else { return }
            guard let webView = object as? WKWebView else { return }
            let key = keyPath
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleKeyValue(key, for: webView)
            }
        }
        
        @MainActor
        private func handleKeyValue(_ keyPath: String?, for webView: WKWebView) {
            // Update the bound tab first; mirror to view-model state only when
            // this tab is the currently visible one.
            if keyPath == "estimatedProgress" {
                mutateBoundTab { $0.estimatedProgress = webView.estimatedProgress }
                if boundTabIsActive {
                    viewModel.estimatedProgress = webView.estimatedProgress
                }
            } else if keyPath == "title" {
                let title = webView.title ?? ""
                if !title.isEmpty {
                    mutateBoundTab { $0.title = title }
                    if boundTabIsActive {
                        viewModel.pageTitle = title
                    }
                }
            } else if keyPath == "URL" {
                if let url = webView.url {
                    mutateBoundTab { tab in
                        tab.url = url
                        tab.inputURLText = url.absoluteString
                        tab.canGoBack = webView.canGoBack
                        tab.canGoForward = webView.canGoForward
                        if url.scheme == "https" || url.scheme == "http" {
                            tab.faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(url.host ?? "")&sz=64")
                        }
                    }
                    if boundTabIsActive {
                        viewModel.currentURL = url
                        viewModel.inputURLText = url.absoluteString
                        viewModel.canGoBack = webView.canGoBack
                        viewModel.canGoForward = webView.canGoForward
                    }
                }
            }
        }
        
        // MARK: - Page scrolling

        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // Dismiss the keyboard + suggestions when the user scrolls the page.
            if boundTabIsActive, viewModel.isAddressFieldFocused {
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
                // Torrent links (magnet URIs and remote `.torrent` URLs) are
                // intercepted BEFORE any generic download detection: the
                // navigation is cancelled, WebKit never sees the magnet
                // scheme, and the torrent confirmation popup is presented.
                if BrowserTorrentLink.isTorrent(url) {
                    decisionHandler(.cancel)
                    Task { @MainActor [weak self] in
                        guard let self, self.boundTabIsActive else { return }
                        self.viewModel.promptTorrent(url: url)
                    }
                    return
                }
                
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
                
                // A server can identify a torrent without a `.torrent` path:
                // `application/x-bittorrent` (or a `.torrent` URL that was
                // redirected). Route these to the torrent flow, never to the
                // generic download engine.
                if BrowserTorrentLink.isRemoteTorrent(responseURL) || mimeType == "application/x-bittorrent" {
                    let contentDisposition = response.allHeaderFields["Content-Disposition"] as? String
                    let filename = contentDisposition.flatMap {
                        URLFilenameExtractor.extractFilename(fromContentDisposition: $0)
                    }
                    Task { @MainActor [weak self] in
                        guard let self, self.boundTabIsActive else { return }
                        self.viewModel.promptTorrent(url: responseURL, filename: filename, mimeType: response.mimeType)
                    }
                    decisionHandler(.cancel)
                    return
                }
                
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
            
            // Torrent links tapped on a page must open the torrent flow, never
            // the generic download popup — even when the anchor carries a
            // `download` attribute.
            if BrowserTorrentLink.isTorrent(url) {
                Task { @MainActor [weak self] in
                    guard let self, self.boundTabIsActive else { return }
                    self.viewModel.promptTorrent(url: url)
                }
                return
            }
            
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mutateBoundTab { tab in
                    tab.isLoading = true
                    tab.isOffline = false
                    tab.isReaderMode = false
                }
                guard self.boundTabIsActive else { return }
                self.viewModel.isLoading = true
                self.viewModel.loadErrorMessage = nil
                self.viewModel.blockedRequestCount = 0
                self.viewModel.isReaderMode = false
                if let host = webView.url?.host {
                    AdBlockEngine.shared.resetCount(forHost: host)
                }
            }
        }
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mutateBoundTab { tab in
                    tab.isLoading = false
                    tab.isOffline = false
                }
                // Incognito tabs never write to browsing history.
                let isPrivate = self.viewModel.tabManager.tab(for: self.tabID)?.isPrivate ?? false
                if !isPrivate, let url = webView.url {
                    BrowserHistoryManager.shared.addHistory(
                        title: webView.title ?? url.host ?? url.absoluteString,
                        urlString: url.absoluteString
                    )
                }
                guard self.boundTabIsActive else { return }
                self.viewModel.isLoading = false
                self.viewModel.loadErrorMessage = nil
            }
        }
        
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mutateBoundTab { $0.isLoading = false }
                guard self.boundTabIsActive else { return }
                self.viewModel.isLoading = false
                self.setLoadError(error)
            }
        }
        
        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mutateBoundTab { tab in
                    tab.isLoading = false
                    tab.isOffline = (error as NSError).code == NSURLErrorNotConnectedToInternet
                }
                guard self.boundTabIsActive else { return }
                self.viewModel.isLoading = false
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
            
            // Popups open in a new tab, inheriting THIS tab's privacy state
            // (never the currently visible tab's — this coordinator is bound
            // to its own tab).
            let isPrivate = viewModel.tabManager.tab(for: tabID)?.isPrivate ?? false
            Task { @MainActor in
                _ = BrowserTabManager.shared.createNewTab(url: url, isPrivate: isPrivate)
            }
            return nil
        }
        
        public func webViewDidClose(_ webView: WKWebView) {
            guard webView === observedWebView else { return }
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
                    let shareAction = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                        Task { @MainActor in
                            ServiceContainer.shared.fileManagementService.shareFile(url: url, from: nil)
                        }
                    }

                    if BrowserTorrentLink.isTorrent(url) {
                        // Torrent links: "Add Torrent" replaces the generic
                        // download action; open/copy stay available.
                        let addTorrentAction = UIAction(title: "Add Torrent", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                            Task { @MainActor [weak self] in
                                self?.viewModel.promptTorrent(url: url)
                            }
                        }
                        actions.append(contentsOf: [openNewTabAction, openPrivateTabAction, copyLinkAction, addTorrentAction, shareAction])
                    } else {
                        let downloadAction = UIAction(title: "Download Link", image: UIImage(systemName: "arrow.down.circle")) { _ in
                            Task { @MainActor in
                                self?.viewModel.promptDownload(url: url)
                            }
                        }
                        actions.append(contentsOf: [openNewTabAction, openPrivateTabAction, copyLinkAction, downloadAction, shareAction])
                    }
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
