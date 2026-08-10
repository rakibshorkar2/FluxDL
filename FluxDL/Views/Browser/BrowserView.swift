import SwiftUI

public struct BrowserView: View {
    @StateObject private var viewModel = BrowserViewModel()
    @ObservedObject private var tabManager = BrowserTabManager.shared
    @State private var chromeHeight: CGFloat = 0
    private let onOpenDownloads: () -> Void
    
    public init(onOpenDownloads: @escaping () -> Void = {}) {
        self.onOpenDownloads = onOpenDownloads
    }
    
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                // Web content — recreated per tab so each tab gets its own live WKWebView
                WebViewContainer(viewModel: viewModel)
                    .id(tabManager.activeTabId)
                    .ignoresSafeArea(edges: .top)
                
                // Error / offline state overlay
                if let message = viewModel.loadErrorMessage {
                    BrowserErrorView(url: viewModel.currentURL, message: message) {
                        viewModel.reloadOrStop()
                    }
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
                }
                
                // Custom chrome: toolbar + find-in-page bar
                VStack(spacing: 0) {
                    BrowserAddressBar(
                        text: $viewModel.inputURLText,
                        isFieldFocused: $viewModel.isAddressFieldFocused,
                        isLoading: viewModel.isLoading,
                        progress: viewModel.estimatedProgress,
                        canGoBack: viewModel.canGoBack,
                        canGoForward: viewModel.canGoForward,
                        tabCount: tabManager.tabs.count,
                        faviconURL: tabManager.activeTab?.faviconURL,
                        isSecure: viewModel.currentURL?.scheme == "https",
                        blockedCount: viewModel.blockedRequestCount,
                        suggestions: viewModel.suggestions,
                        onCommit: { viewModel.handleSearchOrNavigate() },
                        onReload: { viewModel.reloadOrStop() },
                        onGoBack: { viewModel.goBack() },
                        onGoForward: { viewModel.goForward() },
                        onGoHome: { viewModel.goHome() },
                        onOpenTabs: {
                            viewModel.isAddressFieldFocused = false
                            tabManager.isTabGridPresented = true
                        },
                        onFocusChange: { focused in viewModel.isAddressFieldFocused = focused },
                        onSelectSuggestion: { viewModel.selectSuggestion($0) },
                        onClearSuggestions: { viewModel.dismissSuggestions() }
                    ) {
                        moreMenu
                    }
                    
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
                
                // Tab grid — animated overlay (slides up like a sheet)
                if tabManager.isTabGridPresented {
                    BrowserTabGridView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(20)
                        .ignoresSafeArea()
                }
            }
            .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
            .onChange(of: tabManager.activeTabId) { _ in
                viewModel.isChromeCollapsed = false
            }
            .animation(AppTheme.defaultSpring, value: tabManager.isTabGridPresented)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
            "Clear History?",
            isPresented: $viewModel.isClearHistoryPresented,
            titleVisibility: .visible
        ) {
            Button("Clear All History", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all browsing history from this device.")
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
    
    // MARK: - More menu
    
    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            Button {
                viewModel.reloadOrStop()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            
            Button {
                viewModel.stopLoading()
            } label: {
                Label("Stop Loading", systemImage: "xmark")
            }
            .disabled(!viewModel.isLoading)
            
            Divider()
            
            Button {
                viewModel.copyCurrentURL()
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            
            Button {
                viewModel.shareCurrentPage()
            } label: {
                Label("Share...", systemImage: "square.and.arrow.up")
            }
            
            Button {
                viewModel.isFindInPagePresented = true
            } label: {
                Label("Find in Page", systemImage: "magnifyingglass")
            }
            
            Divider()
            
            Button {
                viewModel.toggleDesktopMode()
            } label: {
                if tabManager.activeTab?.isDesktopMode == true {
                    Label("Request Mobile Website", systemImage: "iphone")
                } else {
                    Label("Request Desktop Website", systemImage: "desktopcomputer")
                }
            }
            
            Button {
                viewModel.toggleBookmarkCurrentPage()
            } label: {
                Label("Add Bookmark", systemImage: "bookmark")
            }
            
            Button {
                viewModel.toggleReaderMode()
            } label: {
                Label(viewModel.isReaderMode ? "Exit Reader Mode" : "Reader Mode", systemImage: "text.alignleft")
            }
            
            if let host = viewModel.currentURL?.host, !host.isEmpty,
               BrowserSettings.shared.isAdBlockerEnabled {
                Button {
                    BrowserSettings.shared.toggleWhitelist(domain: host)
                } label: {
                    if BrowserSettings.shared.isWhitelisted(domain: host) {
                        Label("Enable Ad Blocking on This Site", systemImage: "shield")
                    } else {
                        Label("Disable Ad Blocking on This Site", systemImage: "shield.slash")
                    }
                }
            }
            
            Button {
                viewModel.createPrivateTab()
            } label: {
                Label("New Private Tab", systemImage: "eye.slash")
            }
            
            Divider()
            
            Button {
                viewModel.isBookmarksPresented = true
            } label: {
                Label("Bookmarks", systemImage: "bookmark.fill")
            }
            
            Button {
                viewModel.isHistoryPresented = true
            } label: {
                Label("History", systemImage: "clock")
            }
            
            Button(role: .destructive) {
                viewModel.isClearHistoryPresented = true
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            
            Button {
                onOpenDownloads()
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            
            Divider()
            
            Button {
                viewModel.openInSafari()
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
            
            Button {
                viewModel.savePageAsPDF()
            } label: {
                Label("Save Page as PDF", systemImage: "doc.richtext")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.medium))
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions")
    }
}

private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
