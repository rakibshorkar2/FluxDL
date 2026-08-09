import SwiftUI
import WebKit

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
        
        // Apply native Ad Blocker rules
        AdBlockEngine.shared.applyRuleList(to: configuration, domain: activeTab?.url?.host)
        
        // Configure preferences
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = BrowserSettings.shared.isJavaScriptEnabled
        configuration.defaultWebpagePreferences = preferences
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
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
            // Do NOT call uiView.reload() here — desktop/mobile reload is now
            // triggered explicitly by the user via toggleDesktopMode() → updateUIView
            // will be called again by SwiftUI after the tab model change.
        }

        // Only update the findInPage web-view reference when the WKWebView instance itself changes.
        if context.coordinator.observedWebView !== uiView {
            viewModel.findInPageManager.setWebView(uiView)
        }
    }
    
    // MARK: - Coordinator
    
    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var viewModel: BrowserViewModel
        weak var observedWebView: WKWebView?
        
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
                            self.viewModel.tabManager.activeTab = activeTab
                        }
                    }
                }
            }
        }
        
        // MARK: - WKNavigationDelegate
        
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
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
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.viewModel.isLoading = false
                if let url = webView.url {
                    BrowserHistoryManager.shared.addHistory(
                        title: webView.title ?? url.host ?? url.absoluteString,
                        urlString: url.absoluteString
                    )
                }
            }
        }
        
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                self.viewModel.isLoading = true
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
                var actions: [UIAction] = []
                
                if let url = targetURL {
                    let openNewTabAction = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square")) { _ in
                        Task { @MainActor in
                            _ = BrowserTabManager.shared.createNewTab(url: url)
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
                    actions.append(contentsOf: [openNewTabAction, copyLinkAction, downloadAction, shareAction])
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
