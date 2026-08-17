import Foundation
import Combine

/// State of the search index for the active Open Directory root.
public enum DirectoryIndexStatus: Equatable, Sendable {
    case idle
    case indexing
    /// Fully built (or loaded from cache).
    case ready
    /// Built but capped by the crawler safety limit — the server may contain
    /// more files than the index holds.
    case partial
    case error(String)
}

/// Owns the search index lifecycle for Open Directory roots: background
/// crawling (reusing the existing `DirectoryFolderCrawler`), in-memory +
/// on-disk caching, per-root isolation, refresh and invalidation.
///
/// All published state is main-actor bound; the crawl itself runs off the UI
/// thread inside the crawler so the normal directory listing stays responsive.
@MainActor
public final class DirectorySearchService: ObservableObject {

    public static let shared = DirectorySearchService()

    @Published public private(set) var status: DirectoryIndexStatus = .idle
    @Published public private(set) var progress = DirectoryCrawlProgress()
    @Published public private(set) var index: DirectorySearchIndex?
    @Published public private(set) var lastError: String?

    /// Root key of the currently active index.
    public private(set) var activeRootKey: String?

    private let crawler: DirectoryFolderCrawler
    private var memoryCache: [String: DirectorySearchIndex] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var crawlingRootKey: String?

    public init(
        crawler: DirectoryFolderCrawler? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.crawler = crawler ?? DirectoryFolderCrawler()
        self.crawler.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.progress = progress
            }
            .store(in: &cancellables)
    }

    public var isIndexed: Bool { index != nil }

    // MARK: - Index lifecycle

    /// Ensures an index exists for `root`. Loads the cached index (memory,
    /// then disk) when present; otherwise starts a background crawl. Pass
    /// `forceRefresh` to always re-crawl.
    public func ensureIndex(for root: URL, forceRefresh: Bool = false) {
        let key = DirectorySearchRootKey.key(for: root)
        activeRootKey = key

        if !forceRefresh, let cached = memoryCache[key] ?? loadFromDisk(key: key) {
            index = cached
            status = cached.isPartial ? .partial : .ready
            lastError = nil
            return
        }

        startCrawl(root: root, key: key)
    }

    /// Cancels any in-flight crawl (the index keeps whatever it already has).
    public func cancelIndexing() {
        crawler.cancel()
        crawlingRootKey = nil
        if status == .indexing {
            status = index == nil ? .idle : (index?.isPartial == true ? .partial : .ready)
        }
    }

    /// Drops the in-memory and on-disk caches for every root.
    public func clearAllCaches() {
        memoryCache.removeAll()
        index = nil
        activeRootKey = nil
        status = .idle
        guard let directory = cacheDirectoryURL() else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Drops the cache for one root only (other roots are untouched).
    public func clearCache(for root: URL) {
        let key = DirectorySearchRootKey.key(for: root)
        memoryCache.removeValue(forKey: key)
        if activeRootKey == key {
            index = nil
            status = .idle
        }
        if let fileURL = cacheFileURL(for: key) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Crawling

    private func startCrawl(root: URL, key: String) {
        // A crawl for the same root is already in flight — never duplicate.
        guard crawlingRootKey != key else { return }
        // Crawling a different root replaces the old crawl: the crawler
        // cancels its previous task before starting the new one.
        status = .indexing
        progress = DirectoryCrawlProgress()
        lastError = nil
        crawlingRootKey = key
        crawler.crawl(root: root) { [weak self] result in
            guard let self else { return }
            guard self.crawlingRootKey == key else { return }
            self.crawlingRootKey = nil
            guard result.outcome == .finished else {
                if self.index == nil {
                    self.status = .idle
                }
                return
            }
            let isPartial = result.files.count >= self.crawler.maximumFileLimit
            let built = DirectorySearchIndexBuilder.build(
                files: result.files,
                root: root,
                foldersScanned: result.foldersScanned,
                failedFolders: result.failedFolders,
                isPartial: isPartial
            )
            self.memoryCache[key] = built
            self.saveToDisk(built)
            if self.activeRootKey == key {
                self.index = built
                self.status = built.isPartial ? .partial : .ready
                self.lastError = nil
            }
        }
    }

    // MARK: - Persistence

    private func cacheDirectoryURL() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("DirectorySearchIndexes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cacheFileURL(for key: String) -> URL? {
        cacheDirectoryURL()?.appendingPathComponent(DirectorySearchRootKey.cacheFileName(for: key) + ".json")
    }

    private func saveToDisk(_ index: DirectorySearchIndex) {
        guard let fileURL = cacheFileURL(for: index.rootKey),
              let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadFromDisk(key: String) -> DirectorySearchIndex? {
        guard let fileURL = cacheFileURL(for: key),
              let data = try? Data(contentsOf: fileURL),
              let index = try? JSONDecoder().decode(DirectorySearchIndex.self, from: data) else {
            return nil
        }
        memoryCache[key] = index
        return index
    }
}
