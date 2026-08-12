import SwiftUI

/// Professional browser chrome: a fixed header (status row + address bar),
/// the webpage beneath it, and a stable bottom toolbar. The chrome is part
/// of the safe-area layout via `safeAreaInset`, so it never floats over or
/// obscures the webpage, and the keyboard never hides the address bar.
public struct BrowserView: View {
    @StateObject private var viewModel = BrowserViewModel()
    @ObservedObject private var tabManager = BrowserTabManager.shared
    private let onOpenDownloads: () -> Void

    public init(onOpenDownloads: @escaping () -> Void = {}) {
        self.onOpenDownloads = onOpenDownloads
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                webContent(geo: geo)
            }
            .safeAreaInset(edge: .top, spacing: 0) { topChrome }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BrowserWindowOriginKey.self,
                        value: proxy.frame(in: .global).origin
                    )
                }
            )
            .onPreferenceChange(BrowserWindowOriginKey.self) { origin in
                viewModel.browserWindowOrigin = origin
            }
            .animation(AppTheme.defaultSpring, value: tabManager.isTabGridPresented)
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
        .alert(
            "JavaScript",
            isPresented: Binding(
                get: { viewModel.javascriptExecutionMessage != nil },
                set: { if !$0 { viewModel.javascriptExecutionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.javascriptExecutionMessage ?? "")
        }
    }

    // MARK: - Web content area (between the top chrome and bottom toolbar)

    private func webContent(geo: GeometryProxy) -> some View {
        ZStack {
            // Web content — recreated per tab so each tab gets its own live WKWebView
            WebViewContainer(viewModel: viewModel)
                .id(tabManager.activeTabId)

            // Error / offline state overlay
            if let message = viewModel.loadErrorMessage {
                BrowserErrorView(url: viewModel.currentURL, message: message) {
                    viewModel.reloadOrStop()
                }
                .transition(.opacity)
            }

            // "Download File?" popup — anchored to the exact element that
            // triggered the download. Falls back to a toolbar-adjacent
            // position for programmatic (non-element) download triggers.
            if viewModel.showDownloadPrompt, let request = viewModel.pendingDownload {
                let position = downloadPopupPosition(in: geo.size)
                BrowserDownloadPromptView(
                    request: request,
                    onDownload: { viewModel.startDetectedDownload() },
                    onCancel: { viewModel.cancelDetectedDownload() }
                )
                .position(x: position.x, y: position.y)
                .offset(y: position.y < 150 ? 96 : -86)
                .zIndex(30)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.downloadAnchorPoint)
            }

            // Proxy status indicator (non-interactive pill, toolbar-adjacent)
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
                    .padding(.bottom, 10)
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
    }

    // MARK: - Top chrome

    private var topChrome: some View {
        VStack(spacing: 0) {
            statusRow

            BrowserAddressBar(
                text: $viewModel.inputURLText,
                isFieldFocused: $viewModel.isAddressFieldFocused,
                displayHost: viewModel.currentURL?.host ?? "",
                isLoading: viewModel.isLoading,
                progress: viewModel.estimatedProgress,
                faviconURL: tabManager.activeTab?.faviconURL,
                isSecure: viewModel.currentURL?.scheme == "https",
                blockedCount: viewModel.blockedRequestCount,
                suggestions: viewModel.suggestions,
                onCommit: { viewModel.handleSearchOrNavigate() },
                onReload: { viewModel.reloadOrStop() },
                onFocusChange: { focused in viewModel.isAddressFieldFocused = focused },
                onSelectSuggestion: { viewModel.selectSuggestion($0) },
                onClearSuggestions: { viewModel.dismissSuggestions() }
            )

            if viewModel.isFindInPagePresented {
                FindInPageBar(manager: viewModel.findInPageManager) {
                    viewModel.isFindInPagePresented = false
                }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Compact status row: security/private state, page title, More menu.
    private var statusRow: some View {
        HStack(spacing: 6) {
            if tabManager.activeTab?.isPrivate == true {
                Image(systemName: "eye.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.purple)
                Text("Private")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.purple)
            } else if viewModel.currentURL?.scheme == "https" {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.green)
            }

            Text(statusTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            moreMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var statusTitle: String {
        if !viewModel.pageTitle.isEmpty { return viewModel.pageTitle }
        if let host = viewModel.currentURL?.host, !host.isEmpty { return host }
        return tabManager.activeTab?.isPrivate == true ? "Private Tab" : "New Tab"
    }

    // MARK: - Bottom toolbar

    private var bottomBar: some View {
        BrowserToolbar(
            canGoBack: viewModel.canGoBack,
            canGoForward: viewModel.canGoForward,
            tabCount: tabManager.tabs.count,
            onBack: { viewModel.goBack() },
            onForward: { viewModel.goForward() },
            onShare: { viewModel.shareCurrentPage() },
            onOpenTabs: {
                viewModel.isAddressFieldFocused = false
                tabManager.isTabGridPresented = true
            }
        ) {
            moreMenu
        }
    }

    // MARK: - Download popup positioning

    /// Position of the "Download File?" popup: anchored to the DOM element
    /// that triggered the download (clamped inside the safe inset), falling
    /// back to the toolbar-adjacent slot for programmatic triggers.
    private func downloadPopupPosition(in size: CGSize) -> CGPoint {
        let edgeInset: CGFloat = 160
        let halfWidth = max(edgeInset, size.width - edgeInset)
        let origin = viewModel.browserWindowOrigin
        if let anchor = viewModel.downloadAnchorPoint {
            return CGPoint(
                x: min(max(anchor.x - origin.x, edgeInset), halfWidth),
                y: anchor.y - origin.y
            )
        }
        return CGPoint(
            x: min(max(size.width / 2, edgeInset), halfWidth),
            y: size.height - 150
        )
    }

    // MARK: - More menu

    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            Button {
                _ = tabManager.createNewTab()
            } label: {
                Label("New Tab", systemImage: "plus.square")
            }

            Button {
                viewModel.createPrivateTab()
            } label: {
                Label("New Private Tab", systemImage: "eye.slash")
            }

            if !tabManager.recentlyClosedTabs.isEmpty {
                Button {
                    tabManager.restoreLastClosedTab()
                } label: {
                    Label("Restore Last Closed Tab", systemImage: "arrow.uturn.backward")
                }
            }

            Divider()

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
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions")
    }
}

private struct BrowserWindowOriginKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}
