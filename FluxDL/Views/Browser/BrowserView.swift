import SwiftUI

public struct BrowserView: View {
    @StateObject private var viewModel = BrowserViewModel()
    @State private var chromeHeight: CGFloat = 0
    
    public init() {}
    
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                // Web content — recreated per tab so each tab gets its own live WKWebView
                WebViewContainer(viewModel: viewModel)
                    .id(viewModel.tabManager.activeTabId)
                    .ignoresSafeArea(edges: .top)
                
                // Error / offline state overlay
                if let message = viewModel.loadErrorMessage {
                    BrowserErrorView(url: viewModel.currentURL, message: message) {
                        viewModel.reloadOrStop()
                    }
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
                }
                
                // Custom chrome: address bar + find-in-page bar
                VStack(spacing: 0) {
                    BrowserAddressBar(
                        text: $viewModel.inputURLText,
                        isLoading: viewModel.isLoading,
                        progress: viewModel.estimatedProgress,
                        isDesktopMode: viewModel.tabManager.activeTab?.isDesktopMode ?? false,
                        onCommit: { viewModel.handleSearchOrNavigate() },
                        onReload: { viewModel.reloadOrStop() },
                        onToggleDesktop: { viewModel.toggleDesktopMode() },
                        onOpenPageActions: { viewModel.isPageActionsPresented = true }
                    )
                    
                    if viewModel.isFindInPagePresented {
                        FindInPageBar(manager: viewModel.findInPageManager) {
                            viewModel.isFindInPagePresented = false
                        }
                    }
                }
                .background(GeometryReader { chromeGeo in
                    Color.clear.preference(key: ChromeHeightKey.self, value: chromeGeo.size.height)
                })
                .padding(.top, geo.safeAreaInsets.top)
                .offset(y: viewModel.isChromeCollapsed ? -chromeHeight : 0)
                .animation(.easeInOut(duration: 0.22), value: viewModel.isChromeCollapsed)
                
                // Proxy status indicator (non-interactive pill, bottom-right)
                if viewModel.proxySession.isProxyActive, let label = viewModel.proxySession.proxyLabel {
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text(label)
                                .font(.caption2.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
            .onChange(of: viewModel.tabManager.activeTabId) { _ in
                viewModel.isChromeCollapsed = false
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $viewModel.tabManager.isTabGridPresented) {
            BrowserTabGridView()
        }
        .sheet(isPresented: $viewModel.isBookmarksPresented) {
            BrowserBookmarksView { url in
                viewModel.inputURLText = url.absoluteString
                viewModel.handleSearchOrNavigate()
            }
        }
        .sheet(isPresented: $viewModel.isHistoryPresented) {
            BrowserHistoryView { url in
                viewModel.inputURLText = url.absoluteString
                viewModel.handleSearchOrNavigate()
            }
        }
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            BrowserSettingsSheet()
        }
        .confirmationDialog(
            "Page Actions",
            isPresented: $viewModel.isPageActionsPresented,
            titleVisibility: .visible
        ) {
            Button("Reload Page") { viewModel.reloadOrStop() }
            Button(viewModel.tabManager.activeTab?.isDesktopMode == true ? "Request Mobile Website" : "Request Desktop Website") {
                viewModel.toggleDesktopMode()
            }
            Button("Add Bookmark") { viewModel.toggleBookmarkCurrentPage() }
            Button("Copy URL") { viewModel.copyCurrentURL() }
            Button("Share...") { viewModel.shareCurrentPage() }
            Button("Find in Page") { viewModel.isFindInPagePresented = true }
            Button("Open in Safari") { viewModel.openInSafari() }
            Button("Save Page as PDF") { viewModel.savePageAsPDF() }
            Button("Go to Home") { viewModel.goHome() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Download File?",
            isPresented: $viewModel.showDownloadPrompt,
            titleVisibility: .visible
        ) {
            Button("Download Now") {
                viewModel.startDetectedDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let url = viewModel.detectedDownloadURL {
                Text("Detected downloadable file:\n\(url.lastPathComponent)")
            }
        }
    }
}

private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
