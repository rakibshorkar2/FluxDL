import SwiftUI

public struct BrowserView: View {
    @StateObject private var viewModel = BrowserViewModel()
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Address Bar & Progress
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
                
                // Optional Find In Page Floating Bar
                if viewModel.isFindInPagePresented {
                    FindInPageBar(manager: viewModel.findInPageManager) {
                        viewModel.isFindInPagePresented = false
                    }
                }
                
                // Web Content View Container
                WebViewContainer(viewModel: viewModel)
            }
            .navigationTitle(viewModel.pageTitle.isEmpty ? "Browser" : viewModel.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Leading: Back & Forward navigation
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(action: { viewModel.goBack() }) {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!viewModel.canGoBack)

                    Button(action: { viewModel.goForward() }) {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!viewModel.canGoForward)
                }

                // Trailing: Bookmark, Tab count, More menu
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: { viewModel.toggleBookmarkCurrentPage() }) {
                        let isBookmarked = viewModel.bookmarkManager.isBookmarked(
                            urlString: viewModel.currentURL?.absoluteString ?? "")
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(isBookmarked ? Color.accentColor : Color.primary)
                    }

                    // Tab Grid Button with badge count
                    Button(action: { viewModel.tabManager.isTabGridPresented = true }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary, lineWidth: 1.8)
                                .frame(width: 22, height: 22)
                            Text("\(viewModel.tabManager.tabs.count)")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }

                    // Menu for History, Settings, Find in page, etc.
                    Menu {
                        Button(action: { viewModel.isBookmarksPresented = true }) {
                            Label("Bookmarks", systemImage: "bookmark")
                        }
                        Button(action: { viewModel.isHistoryPresented = true }) {
                            Label("History", systemImage: "clock")
                        }
                        Button(action: { viewModel.isFindInPagePresented.toggle() }) {
                            Label("Find in Page", systemImage: "magnifyingglass")
                        }
                        Button(action: { viewModel.isSettingsPresented = true }) {
                            Label("Browser Settings", systemImage: "gear")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
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
}
