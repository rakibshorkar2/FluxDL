import Foundation
import UIKit
import Combine

/// One tappable breadcrumb segment of the current directory path.
public struct DirectoryBreadcrumb: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.id = url.absoluteString
        self.title = title
        self.url = url
    }
}

/// State of the in-app media playback sheet.
public struct DirectoryPlaybackRequest: Identifiable, Equatable {
    public let id: UUID
    public let item: DirectoryItem
    public let playlist: [DirectoryItem]

    public init(id: UUID = UUID(), item: DirectoryItem, playlist: [DirectoryItem]) {
        self.id = id
        self.item = item
        self.playlist = playlist
    }
}

/// State of the folder download preview (crawl results + user selection).
public struct DirectoryFolderDownloadRequest: Identifiable, Equatable {
    public let id: UUID = UUID()
    public let folderName: String
    public let folderURL: URL
    public var files: [CrawledFile]
    public var selectedIDs: Set<UUID>
    public let failedFolders: [String]
    public var wasCancelled: Bool

    public var selectedFiles: [CrawledFile] {
        files.filter { selectedIDs.contains($0.id) }
    }

    public var totalSelectedBytes: Int64 {
        selectedFiles.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
    }

    public var filterText: String = ""
}

/// The DirXplore-inspired Open Directory Browser.
///
/// Owns one independent navigation session (address bar, back stack,
/// breadcrumbs, list/grid layout, filter/category/sort, selection, history)
/// that lives as long as the Browser tab does, so switching between Web Mode
/// and Directory Mode preserves both worlds' state.
@MainActor
public final class DirectoryBrowserViewModel: ObservableObject {

    // MARK: - State

    @Published public var inputText: String = ""
    @Published public var currentURL: URL?
    @Published public var items: [DirectoryItem] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var isProxied = false
    @Published public var proxyLabel: String?

    @Published public var canGoBack = false
    @Published public var canGoUp = false
    @Published public var breadcrumbs: [DirectoryBreadcrumb] = []

    @Published public var filterText: String = ""
    @Published public var category: DirectoryCategory = .all
    @Published public var sort: DirectorySortOption = .foldersFirst
    @Published public var isGridView = false

    @Published public var isSelecting = false
    @Published public var selectedIDs: Set<UUID> = []

    @Published public var fallbackURL: URL?
    @Published public var isFallbackVisible = false

    @Published public var playbackRequest: DirectoryPlaybackRequest?
    @Published public var folderDownloadRequest: DirectoryFolderDownloadRequest?
    @Published public var crawlProgress = DirectoryCrawlProgress()

    @Published public var isBookmarksPresented = false
    @Published public var isHistoryPresented = false
    @Published public var toastMessage: String?

    private var backStack: [URL] = []
    private var loadTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private let client = DirectoryHTTPClient.shared
    private let crawler: DirectoryFolderCrawler
    private let history = DirectoryHistoryManager.shared
    private let bookmarks = BookmarkManager.shared
    private let engine = ServiceContainer.shared.downloadEngine
    private let queueManager = ServiceContainer.shared.queueManager

    private let layoutKey = "fluxdl_directory_layout"
    private let sortKey = "fluxdl_directory_sort"
    private let categoryKey = "fluxdl_directory_category"

    // MARK: - Init

    public init(crawler: DirectoryFolderCrawler? = nil) {
        self.crawler = crawler ?? DirectoryFolderCrawler()
        isGridView = UserDefaults.standard.bool(forKey: layoutKey)
        if let raw = UserDefaults.standard.string(forKey: sortKey),
           let option = DirectorySortOption(rawValue: raw) {
            sort = option
        }
        if let raw = UserDefaults.standard.string(forKey: categoryKey),
           let value = DirectoryCategory(rawValue: raw) {
            category = value
        }

        BrowserProxySession.shared.proxyDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleProxyChange() }
            .store(in: &cancellables)
        syncProxyState()

        self.crawler.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in self?.crawlProgress = progress }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    public var displayItems: [DirectoryItem] {
        let filtered = items.filter { item in
            guard !filterText.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(filterText)
        }
        let categorized = filtered.filter { category.matches($0) }
        return sort.sorted(categorized)
    }

    public var canDownloadSelection: Bool {
        !selectedIDs.isEmpty
    }

    public var selectedCount: Int { selectedIDs.count }

    /// All playable items of the current listing — used to build the
    /// playlist for in-app playback.
    public var playableItems: [DirectoryItem] {
        items.filter { $0.type.isPlayableMedia }
    }

    // MARK: - Navigation

    public func normalizeURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        guard let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        return url
    }

    public func load(input: String) {
        guard let url = normalizeURL(input) else {
            errorMessage = DirectoryHTTPError.invalidURL.localizedDescription
            return
        }
        load(url: url, addToBackStack: true)
    }

    public func load(url: URL, addToBackStack: Bool = true) {
        loadTask?.cancel()
        errorMessage = nil
        isFallbackVisible = false
        fallbackURL = nil
        clearSelection()

        var normalized = url
        if normalized.path.isEmpty {
            var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false)
            components?.path = "/"
            if let updated = components?.url {
                normalized = updated
            }
        }

        if addToBackStack {
            backStack.append(normalized)
        }
        updateNavigationState()
        inputText = normalized.absoluteString
        currentURL = normalized

        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(url: normalized)
        }
    }

    private func performLoad(url: URL) async {
        let result: DirectoryFetchResult
        do {
            result = try await client.fetch(url: url)
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            items = []
            errorMessage = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }

        let parsed = await Task.detached(priority: .userInitiated) {
            DirectoryHTMLParser.parse(html: result.data, baseURL: result.finalURL)
        }.value

        guard !Task.isCancelled else { return }

        if DirectoryDetector.isOpenDirectory(parsed, contentType: result.contentType) {
            items = parsed.items
            isLoading = false
            currentURL = result.finalURL
            if result.finalURL != url {
                if backStack.last == url { backStack[backStack.count - 1] = result.finalURL }
                inputText = result.finalURL.absoluteString
            }
            updateNavigationState()
            history.addHistory(title: titleForHistory(url: result.finalURL), urlString: result.finalURL.absoluteString)
        } else {
            isLoading = false
            items = []
            fallbackURL = result.finalURL
            isFallbackVisible = true
            updateNavigationState()
        }
    }

    public func reload() {
        guard let url = currentURL else { return }
        load(url: url, addToBackStack: false)
    }

    public func goBack() {
        guard backStack.count > 1 else { return }
        backStack.removeLast()
        guard let url = backStack.last else { return }
        load(url: url, addToBackStack: false)
    }

    public func goUp() {
        guard let current = currentURL else { return }
        var components = URLComponents(url: current, resolvingAgainstBaseURL: false)
        var path = components?.path ?? "/"
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        if path.isEmpty || path == "/" { return }
        let parentPath = (path as NSString).deletingLastPathComponent
        components?.path = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard let parent = components?.url else { return }
        load(url: parent)
    }

    public func goToBreadcrumb(_ crumb: DirectoryBreadcrumb) {
        load(url: crumb.url)
    }

    private func updateNavigationState() {
        canGoBack = backStack.count > 1
        canGoUp = {
            guard let path = currentURL?.path else { return false }
            let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
            return !normalized.isEmpty && normalized != "/"
        }()
        breadcrumbs = makeBreadcrumbs(for: currentURL)
    }

    private func makeBreadcrumbs(for url: URL?) -> [DirectoryBreadcrumb] {
        guard let url, let host = url.host, !host.isEmpty else { return [] }
        var crumbs: [DirectoryBreadcrumb] = []
        var hostComponents = URLComponents()
        hostComponents.scheme = url.scheme
        hostComponents.host = host
        if let port = url.port {
            hostComponents.port = port
        }
        crumbs.append(DirectoryBreadcrumb(title: host, url: hostComponents.url ?? url))

        let path = url.path
        var segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var accumulated = ""
        for segment in segments {
            accumulated += "/" + segment
            let decoded = segment.removingPercentEncoding ?? segment
            var comps = URLComponents()
            comps.scheme = url.scheme
            comps.host = host
            if let port = url.port { comps.port = port }
            comps.path = accumulated + "/"
            crumbs.append(DirectoryBreadcrumb(title: decoded, url: comps.url ?? url))
        }
        return crumbs
    }

    private func titleForHistory(url: URL) -> String {
        let last = url.pathComponents.filter { $0 != "/" }.last
        return last?.removingPercentEncoding ?? url.host ?? url.absoluteString
    }

    // MARK: - Selection

    public func toggleSelection(_ item: DirectoryItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    public func selectAll() {
        selectedIDs = Set(displayItems.map(\.id))
    }

    public func deselectAll() {
        selectedIDs.removeAll()
    }

    public func clearSelection() {
        selectedIDs.removeAll()
        isSelecting = false
    }

    // MARK: - Downloads (existing DownloadEngine only)

    /// Queues the selected (or given) items into the existing FluxDL
    /// DownloadEngine. Duplicates detected by the existing queue manager are
    /// skipped; returns (queued, duplicates).
    @discardableResult
    public func download(items: [DirectoryItem]) -> (queued: Int, duplicates: Int) {
        var queued = 0
        var duplicates = 0
        for item in items where item.type != .directory {
            if queueManager.isDuplicate(url: item.url, in: engine) {
                duplicates += 1
                continue
            }
            engine.startDownload(url: item.url, filename: item.name)
            queued += 1
        }
        if queued > 0 {
            showToast("\(queued) file\(queued == 1 ? "" : "s") added to downloads")
        }
        clearSelection()
        return (queued, duplicates)
    }

    public func downloadSelected() {
        let selected = items.filter { selectedIDs.contains($0.id) }
        download(items: selected)
    }

    public func downloadFolderPreview(_ request: DirectoryFolderDownloadRequest) {
        var queued = 0
        var duplicates = 0
        for file in request.selectedFiles {
            if queueManager.isDuplicate(url: file.url, in: engine) {
                duplicates += 1
                continue
            }
            engine.startDownload(url: file.url, filename: file.name)
            queued += 1
        }
        folderDownloadRequest = nil
        if queued > 0 {
            showToast("\(queued) file\(queued == 1 ? "" : "s") added to downloads")
        } else if duplicates > 0 {
            showToast("All selected files are already in downloads")
        }
    }

    // MARK: - Folder crawling

    public func startFolderCrawl(_ item: DirectoryItem) {
        guard item.type == .directory else { return }
        crawlProgress = DirectoryCrawlProgress()
        crawler.crawl(root: item.url) { [weak self] result in
            guard let self else { return }
            self.crawlProgress = DirectoryCrawlProgress()
            self.folderDownloadRequest = DirectoryFolderDownloadRequest(
                folderName: item.name,
                folderURL: item.url,
                files: result.files,
                selectedIDs: Self.defaultSelection(for: result.files),
                failedFolders: result.failedFolders,
                wasCancelled: result.outcome == .cancelled
            )
        }
    }

    public func cancelFolderCrawl() {
        crawler.cancel()
        crawlProgress = DirectoryCrawlProgress()
    }

    /// Videos/archives and high-res named files are pre-selected, matching
    /// DirXplore's smart default selection.
    private static func defaultSelection(for files: [CrawledFile]) -> Set<UUID> {
        let wantedKeywords = ["1080p", "720p", "bluray", "bdrip"]
        return Set(files.filter { file in
            if file.type == .video || file.type == .archive { return true }
            let name = file.name.lowercased()
            return wantedKeywords.contains { name.contains($0) }
        }.map(\.id))
    }

    // MARK: - Media playback

    public func play(_ item: DirectoryItem) {
        let playlist = playableItems
        playbackRequest = DirectoryPlaybackRequest(item: item, playlist: playlist.isEmpty ? [item] : playlist)
    }

    public func share(_ item: DirectoryItem) {
        let activity = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        topViewController()?.present(activity, animated: true)
    }

    public func openExternally(_ item: DirectoryItem) {
        UIApplication.shared.open(item.url)
    }

    // MARK: - Bookmarks (existing BookmarkManager, shared database)

    public func bookmarkCurrent() {
        guard let url = currentURL else { return }
        let title = titleForHistory(url: url)
        bookmarks.addBookmark(title: title, urlString: url.absoluteString)
        showToast("Bookmarked \(title)")
    }

    public func isCurrentBookmarked() -> Bool {
        guard let url = currentURL else { return false }
        return bookmarks.isBookmarked(urlString: url.absoluteString)
    }

    // MARK: - Proxy

    private func syncProxyState() {
        isProxied = client.isProxyActive
        proxyLabel = client.proxyLabel
    }

    private func handleProxyChange() {
        syncProxyState()
        DirectoryThumbnailLoader.shared.clearCache()
        if let url = currentURL, !isLoading {
            load(url: url, addToBackStack: false)
        }
    }

    // MARK: - UI helpers

    public func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.toastMessage = nil
        }
    }

    public func persistLayoutPreference() {
        UserDefaults.standard.set(isGridView, forKey: layoutKey)
        UserDefaults.standard.set(sort.rawValue, forKey: sortKey)
        UserDefaults.standard.set(category.rawValue, forKey: categoryKey)
    }

    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }
}