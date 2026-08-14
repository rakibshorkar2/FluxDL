import SwiftUI

/// Root container for the DirXplore-inspired Directory Mode of the Browser
/// tab. Occupies the same layout region as the web content and is swapped in
/// via the mode toggle — the WKWebView itself stays alive underneath, hidden.
public struct DirectoryModeView: View {
    @ObservedObject var viewModel: DirectoryBrowserViewModel
    let onOpenInWebBrowser: (URL) -> Void

    public init(viewModel: DirectoryBrowserViewModel, onOpenInWebBrowser: @escaping (URL) -> Void) {
        self.viewModel = viewModel
        self.onOpenInWebBrowser = onOpenInWebBrowser
    }

    public var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSelecting {
                DirectorySelectionToolbar(
                    count: viewModel.selectedCount,
                    onDownload: { viewModel.downloadSelected() },
                    onSelectAll: { viewModel.selectAll() },
                    onDeselectAll: { viewModel.deselectAll() },
                    onCancel: { viewModel.clearSelection() }
                )
            }

            content
        }
        .sheet(item: $viewModel.playbackRequest) { request in
            DirectoryMediaPlayerView(viewModel: viewModel, request: request)
        }
        .sheet(item: $viewModel.folderDownloadRequest) { _ in
            DirectoryFolderDownloadPreview(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isScanningFolder) {
            DirectoryFolderScanProgressView(
                folderName: viewModel.scanningFolderName ?? "",
                progress: viewModel.crawlProgress,
                onCancel: { viewModel.cancelFolderCrawl() }
            )
        }
        .sheet(isPresented: $viewModel.isBookmarksPresented) {
            bookmarksSheet
        }
        .sheet(isPresented: $viewModel.isHistoryPresented) {
            historySheet
        }
        .overlay(alignment: .bottom) { toastOverlay }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            loadingState
        } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
            errorState(error)
        } else if viewModel.isFallbackVisible, let url = viewModel.fallbackURL {
            fallbackState(url)
        } else if viewModel.items.isEmpty {
            emptyState
        } else {
            listingState
        }
    }

    private var listingState: some View {
        VStack(spacing: 0) {
            DirectoryBreadcrumbView(breadcrumbs: viewModel.breadcrumbs) { crumb in
                viewModel.goToBreadcrumb(crumb)
            }
            DirectoryCategoryPicker(category: $viewModel.category)
            if !viewModel.isSelecting {
                DirectoryFilterBar(text: $viewModel.filterText)
            }
            Divider()

            if viewModel.isGridView {
                DirectoryGridView(
                    items: viewModel.displayItems,
                    isSelecting: viewModel.isSelecting,
                    selectedIDs: viewModel.selectedIDs,
                    onOpen: { open($0) },
                    onToggleSelection: { viewModel.toggleSelection($0) },
                    onDownload: { viewModel.download(items: [$0]) },
                    onShare: { viewModel.share($0) },
                    onCopyName: { viewModel.copyName($0) },
                    onResolveSize: { viewModel.resolveSize($0) },
                    onDownloadFolder: { viewModel.startFolderDownload($0) },
                    onBookmark: { viewModel.bookmark($0) }
                )
            } else {
                DirectoryListView(
                    items: viewModel.displayItems,
                    isSelecting: viewModel.isSelecting,
                    selectedIDs: viewModel.selectedIDs,
                    onOpen: { open($0) },
                    onToggleSelection: { viewModel.toggleSelection($0) },
                    onDownload: { viewModel.download(items: [$0]) },
                    onShare: { viewModel.share($0) },
                    onCopyName: { viewModel.copyName($0) },
                    onResolveSize: { viewModel.resolveSize($0) },
                    onDownloadFolder: { viewModel.startFolderDownload($0) },
                    onBookmark: { viewModel.bookmark($0) }
                )
            }
        }
    }

    private func open(_ item: DirectoryItem) {
        switch item.type {
        case .directory:
            viewModel.load(url: item.url)
        default:
            if item.type.isPlayableMedia {
                viewModel.play(item)
            } else {
                viewModel.share(item)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading directory…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("This directory is empty")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fallbackState(_ url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("This doesn't look like an open directory")
                .font(.headline)
            Text("The server responded with a regular web page. Open it in the web browser instead?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                onOpenInWebBrowser(url)
            } label: {
                Label("Open in Web Browser", systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bookmarks / history sheets

    private var bookmarksSheet: some View {
        NavigationView {
            List {
                ForEach(BookmarkManager.shared.bookmarks) { bookmark in
                    Button {
                        guard let url = URL(string: bookmark.urlString) else { return }
                        viewModel.isBookmarksPresented = false
                        viewModel.load(url: url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bookmark.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(bookmark.urlString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        BookmarkManager.shared.removeBookmark(id: BookmarkManager.shared.bookmarks[index].id)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { viewModel.isBookmarksPresented = false }
                }
            }
        }
    }

    private var historySheet: some View {
        NavigationView {
            List {
                ForEach(DirectoryHistoryManager.shared.historyItems) { entry in
                    Button {
                        guard let url = URL(string: entry.urlString) else { return }
                        viewModel.isHistoryPresented = false
                        viewModel.load(url: url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(entry.urlString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        DirectoryHistoryManager.shared.deleteEntry(id: DirectoryHistoryManager.shared.historyItems[index].id)
                    }
                }
            }
            .navigationTitle("Directory History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { viewModel.isHistoryPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear All") { DirectoryHistoryManager.shared.clearAllHistory() }
                }
            }
        }
    }

    // MARK: - Toast

    private var toastOverlay: some View {
        Group {
            if let message = viewModel.toastMessage {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground).opacity(0.95), in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityLabel(message)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.toastMessage)
    }
}