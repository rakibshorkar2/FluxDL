import Foundation
import Combine

/// One file discovered by the recursive folder crawler.
public struct CrawledFile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let url: URL
    public let sizeBytes: Int64?
    public let type: DirectoryItemType
    /// Server-side path relative to the scanned root, e.g. `"Extras/Trailer.mp4"`.
    /// Empty for files directly inside the root folder.
    public let relativePath: String
    /// Last-modified date when the server exposed one (used by the search index).
    public let modifiedDate: Date?
    /// MIME type when the server exposed one (used by the search index).
    public let mimeType: String?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        sizeBytes: Int64?,
        type: DirectoryItemType,
        relativePath: String = "",
        modifiedDate: Date? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
        self.type = type
        self.relativePath = relativePath
        self.modifiedDate = modifiedDate
        self.mimeType = mimeType
    }
}

/// Progress snapshot reported while a folder scan is running.
public struct DirectoryCrawlProgress: Equatable, Sendable {
    public var visitedFolders: Int
    public var filesFound: Int
    public var currentFolder: String?

    public init(visitedFolders: Int = 0, filesFound: Int = 0, currentFolder: String? = nil) {
        self.visitedFolders = visitedFolders
        self.filesFound = filesFound
        self.currentFolder = currentFolder
    }
}

/// Shared, thread-safe state of an in-flight crawl.
private actor CrawlState {
    private var visited = Set<String>()
    private(set) var files: [CrawledFile] = []
    private(set) var failed: [String] = []
    private let maxFiles: Int

    init(maxFiles: Int) {
        self.maxFiles = maxFiles
    }

    /// Returns false when this folder was already visited (cycle).
    func visit(_ key: String) -> Bool {
        if visited.contains(key) { return false }
        visited.insert(key)
        return true
    }

    /// Returns false when the file cap has been reached.
    @discardableResult
    func addFile(_ file: CrawledFile) -> Bool {
        guard files.count < maxFiles else { return false }
        files.append(file)
        return true
    }

    func addFailed(_ urlString: String) {
        failed.append(urlString)
    }

    func snapshot() -> (visited: Int, files: Int) {
        (visited.count, files.count)
    }
}

/// Recursively discovers files under an open-directory root.
///
/// Constraints (DirXplore-inspired, hardened):
/// - Never escapes the target tree: every followed link must resolve to the
///   same scheme+host and a normalized path inside the root's path prefix.
/// - Visited-set cycle prevention + depth limit + file-count cap.
/// - Bounded concurrency with cooperative cancellation; inaccessible
///   subdirectories are recorded, never fatal.
@MainActor
public final class DirectoryFolderCrawler: ObservableObject {

    public enum CrawlOutcome: Sendable {
        case finished
        case cancelled
    }

    public struct CrawlResult: Sendable {
        public let files: [CrawledFile]
        public let failedFolders: [String]
        public let outcome: CrawlOutcome
        /// Number of directories successfully visited (including the root).
        public let foldersScanned: Int

        public init(
            files: [CrawledFile],
            failedFolders: [String],
            outcome: CrawlOutcome,
            foldersScanned: Int = 0
        ) {
            self.files = files
            self.failedFolders = failedFolders
            self.outcome = outcome
            self.foldersScanned = foldersScanned
        }
    }

    @Published public private(set) var progress = DirectoryCrawlProgress()

    private let client: DirectoryHTTPClient
    private var crawlTask: Task<Void, Never>?
    private let maxDepth = 24
    private let maxFiles = 2_000

    public init(client: DirectoryHTTPClient = .shared) {
        self.client = client
    }

    /// The file cap of a single crawl. Indexes built from a crawl whose file
    /// count reaches this limit are partial.
    public var maximumFileLimit: Int { maxFiles }

    public var isCrawling: Bool { crawlTask != nil }

    public func cancel() {
        crawlTask?.cancel()
        crawlTask = nil
    }

    /// Starts a crawl; the result is delivered through the completion
    /// closure on the main actor. Call `cancel()` to abort at any time.
    public func crawl(root: URL, completion: @escaping (CrawlResult) -> Void) {
        crawlTask?.cancel()
        progress = DirectoryCrawlProgress()
        crawlTask = Task { [weak self] in
            guard let self else {
                completion(CrawlResult(files: [], failedFolders: [], outcome: .cancelled))
                return
            }
            let state = CrawlState(maxFiles: self.maxFiles)
            let rootHost = root.host?.lowercased() ?? ""
            let rootPath = self.normalizedPath(root.path)
            await self.crawlFolder(
                url: root,
                rootHost: rootHost,
                rootPath: rootPath,
                relativePrefix: "",
                depth: 0,
                state: state
            )
            let files = await state.files
            let failed = await state.failed
            let visited = await state.snapshot().visited
            let outcome: CrawlOutcome = Task.isCancelled ? .cancelled : .finished
            completion(CrawlResult(
                files: files,
                failedFolders: failed,
                outcome: outcome,
                foldersScanned: visited
            ))
            self.crawlTask = nil
        }
    }

    // MARK: - Recursion

    private func crawlFolder(
        url: URL,
        rootHost: String,
        rootPath: String,
        relativePrefix: String,
        depth: Int,
        state: CrawlState
    ) async {
        guard !Task.isCancelled else { return }
        guard depth <= maxDepth else { return }

        let key = crawlKey(url)
        guard await state.visit(key) else { return }

        let snapshot = await state.snapshot()
        progress = DirectoryCrawlProgress(
            visitedFolders: snapshot.visited,
            filesFound: snapshot.files,
            currentFolder: url.path
        )

        let result: DirectoryFetchResult
        do {
            result = try await client.fetch(url: url)
        } catch {
            await state.addFailed(url.absoluteString)
            return
        }

        let parsed = await Task.detached(priority: .userInitiated) {
            DirectoryHTMLParser.parse(html: result.data, baseURL: result.finalURL)
        }.value

        let entries = parsed.items
        let fileEntries = entries.filter { $0.type != .directory }
        let folderEntries = entries.filter { $0.type == .directory }

        for entry in fileEntries {
            let file = CrawledFile(
                name: entry.name,
                url: entry.url,
                sizeBytes: entry.sizeBytes,
                type: entry.type,
                relativePath: relativePrefix + entry.name,
                modifiedDate: entry.modifiedDate,
                mimeType: entry.mimeType
            )
            if !(await state.addFile(file)) { break }
        }

        let allowedFolders = folderEntries.filter { entry in
            guard entry.url.host?.lowercased() == rootHost else { return false }
            let path = normalizedPath(entry.url.path)
            return path.hasPrefix(rootPath) && path != rootPath
        }

        // Bounded concurrency: at most four in-flight folder fetches.
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for folder in allowedFolders {
                if inFlight >= 4 {
                    await group.next()
                    inFlight -= 1
                }
                group.addTask { [weak self] in
                    await self?.crawlFolder(
                        url: folder.url,
                        rootHost: rootHost,
                        rootPath: rootPath,
                        relativePrefix: relativePrefix + folder.name + "/",
                        depth: depth + 1,
                        state: state
                    )
                }
                inFlight += 1
            }
            await group.waitForAll()
        }
    }

    /// Normalizes a path: resolves "." and ".." segments so a hostile
    /// relative link can never climb out of the root tree.
    private func normalizedPath(_ path: String) -> String {
        var stack: [String] = []
        for component in path.split(separator: "/") {
            let c = String(component)
            if c == "." || c.isEmpty { continue }
            if c == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(c)
        }
        return "/" + stack.joined(separator: "/")
    }

    private func crawlKey(_ url: URL) -> String {
        normalizedPath(url.path) + "?" + (url.query ?? "")
    }
}