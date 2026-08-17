import SwiftUI

/// Professional browser chrome: a fixed header (status row + address bar),
/// the webpage beneath it, and a stable bottom toolbar. The chrome is part
/// of the safe-area layout via `safeAreaInset`, so it never floats over or
/// obscures the webpage, and the keyboard never hides the address bar.
public struct BrowserView: View {
    @StateObject private var viewModel = BrowserViewModel()
    @StateObject private var directoryViewModel = DirectoryBrowserViewModel()
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

            // Tab grid — full-screen layer ABOVE the chrome. It must not live
            // inside the content ZStack: safeAreaInset chrome renders above the
            // base content, so a grid that ignores safe areas slid under the
            // address bar (cards hidden, touches swallowed by the chrome).
            // As an overlay it covers the whole screen — chrome included — and
            // its own navigation bar stays fully visible and interactive.
            .overlay {
                if tabManager.isTabGridPresented, viewModel.browserMode == .web {
                    BrowserTabGridView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
            // Web content — recreated per tab so each tab gets its own live
            // WKWebView. The container is explicitly bound to the active
            // tab's immutable ID: every WebKit callback is attributed to that
            // exact tab and can never mutate a different one. Hidden (never
            // removed) while Directory Mode is active so the active tab keeps
            // its complete web state.
            WebViewContainer(viewModel: viewModel, tabID: tabManager.activeTabId)
                .id(tabManager.activeTabId)
                .opacity(viewModel.browserMode == .web ? 1 : 0)
                .allowsHitTesting(viewModel.browserMode == .web)
                .accessibilityHidden(viewModel.browserMode != .web)

            // Directory Mode — the DirXplore-inspired open-directory browser.
            if viewModel.browserMode == .directory {
                DirectoryModeView(
                    viewModel: directoryViewModel,
                    onOpenInWebBrowser: { viewModel.openInWebBrowser($0) }
                )
                .transition(.opacity)
            }

            // Web-only overlays
            if viewModel.browserMode == .web {
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

                // "Add Torrent?" popup — dedicated torrent flow for magnet
                // links and remote `.torrent` files. Never part of the
                // generic download popup.
                if viewModel.showTorrentPrompt, let prompt = viewModel.torrentPrompt {
                    let position = torrentPopupPosition(in: geo.size)
                    BrowserTorrentPromptView(
                        prompt: prompt,
                        isLoading: viewModel.isTorrentPromptLoading,
                        errorMessage: viewModel.torrentPromptErrorMessage,
                        onAdd: { viewModel.startTorrentAddition() },
                        onCancel: { viewModel.cancelTorrentPrompt() }
                    )
                    .position(x: position.x, y: position.y)
                    .zIndex(31)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
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
            }

        }
    }

    // MARK: - Top chrome

    private var topChrome: some View {
        VStack(spacing: 0) {
            statusRow

            if viewModel.browserMode == .directory {
                DirectoryAddressBar(
                    text: $directoryViewModel.inputText,
                    isLoading: directoryViewModel.isLoading,
                    isProxied: directoryViewModel.isProxied,
                    proxyLabel: directoryViewModel.proxyLabel,
                    onCommit: { directoryViewModel.load(input: directoryViewModel.inputText) },
                    onReload: { directoryViewModel.reload() }
                )
            } else {
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
            }

            if viewModel.browserMode != .directory, viewModel.isFindInPagePresented {
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

            // Web / Directory mode switcher
            modeSwitcher

            moreMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    /// Compact Web/Directory mode capsule. Switching hides (never destroys)
    /// the WKWebView and swaps the chrome; both states persist.
    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            Button {
                viewModel.browserMode = .web
            } label: {
                Image(systemName: "globe")
                    .font(.caption2)
                    .frame(width: 24, height: 20)
                    .foregroundStyle(viewModel.browserMode == .web ? Color.white : Color.secondary)
                    .background(
                        viewModel.browserMode == .web ? Color.accentColor : Color.clear,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Web Browser Mode")
            .accessibilityAddTraits(viewModel.browserMode == .web ? .isSelected : [])

            Button {
                viewModel.browserMode = .directory
            } label: {
                Image(systemName: "folder")
                    .font(.caption2)
                    .frame(width: 24, height: 20)
                    .foregroundStyle(viewModel.browserMode == .directory ? Color.white : Color.secondary)
                    .background(
                        viewModel.browserMode == .directory ? Color.accentColor : Color.clear,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Directory Mode")
            .accessibilityAddTraits(viewModel.browserMode == .directory ? .isSelected : [])
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .animation(AppTheme.quickSpring, value: viewModel.browserMode)
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        if !viewModel.pageTitle.isEmpty { return viewModel.pageTitle }
        if let host = viewModel.currentURL?.host, !host.isEmpty { return host }
        return tabManager.activeTab?.isPrivate == true ? "Private Tab" : "New Tab"
    }

    // MARK: - Bottom toolbar

    @ViewBuilder
    private var bottomBar: some View {
        if viewModel.browserMode == .directory {
            DirectoryBottomBar(viewModel: directoryViewModel)
        } else {
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

    /// Position of the "Add Torrent?" popup: toolbar-adjacent slot, clamped
    /// inside the safe inset (magnet / torrent triggers carry no DOM anchor).
    private func torrentPopupPosition(in size: CGSize) -> CGPoint {
        let edgeInset: CGFloat = 160
        let halfWidth = max(edgeInset, size.width - edgeInset)
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
