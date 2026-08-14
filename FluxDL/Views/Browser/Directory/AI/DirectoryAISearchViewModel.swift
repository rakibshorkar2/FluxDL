import Foundation
import Combine

/// Drives the AI Search sheet: debounced local search against the index,
/// optional Gemini query interpretation on submit, safe fallback to local
/// results whenever AI is unavailable, and index status presentation.
@MainActor
public final class DirectoryAISearchViewModel: ObservableObject {

    @Published public var searchText: String = ""
    @Published public private(set) var results: [DirectorySearchResult] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var didSubmit = false
    /// Informational banner: "AI-assisted search" or
    /// "AI unavailable — showing local search results".
    @Published public private(set) var aiMessage: String?
    @Published public var isSettingsPresented = false

    public let searchService: DirectorySearchService
    /// The Open Directory root the index belongs to. Follows the directory
    /// session when the user switches roots.
    public private(set) var rootURL: URL

    private let aiProvider: DirectorySearchAIProviding?
    private let haptics: HapticServiceProtocol
    private var debounceTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var searchGeneration = 0

    public init(
        searchService: DirectorySearchService? = nil,
        rootURL: URL,
        aiProvider: DirectorySearchAIProviding? = nil,
        haptics: HapticServiceProtocol? = nil
    ) {
        self.searchService = searchService ?? DirectorySearchService.shared
        self.rootURL = rootURL
        self.aiProvider = aiProvider ?? GeminiDirectorySearchService()
        self.haptics = haptics ?? ServiceContainer.shared.hapticService
    }

    // MARK: - Index status

    /// Re-points the sheet at a new Open Directory root (called when the user
    /// switches servers/roots). Cancels stale work and rebuilds/loads the new
    /// root's own index — indexes from different roots never mix.
    public func updateRoot(_ url: URL?) {
        guard let url else { return }
        guard url.absoluteString != rootURL.absoluteString else { return }
        rootURL = url
        searchGeneration += 1
        debounceTask?.cancel()
        aiTask?.cancel()
        results = []
        aiMessage = nil
        isSearching = false
        searchService.ensureIndex(for: url)
    }

    /// Ensure the root's index exists when the sheet opens (loads cache or
    /// starts a background crawl). Never blocks the UI.
    public func ensureIndex() {
        searchService.ensureIndex(for: rootURL)
    }

    public func refreshIndex() {
        debounceTask?.cancel()
        aiTask?.cancel()
        results = []
        searchService.ensureIndex(for: rootURL, forceRefresh: true)
        haptics.selectionChanged()
    }

    public func clearIndex() {
        searchService.clearCache(for: rootURL)
        results = []
        aiMessage = nil
        searchService.ensureIndex(for: rootURL)
        haptics.selectionChanged()
    }

    /// Human-readable index status line shown in the sheet.
    public var indexStatusText: String? {
        switch searchService.status {
        case .idle:
            return nil
        case .indexing:
            let progress = searchService.progress
            return "Indexing… \(progress.filesFound) files / \(progress.visitedFolders) folders"
        case .ready:
            guard let index = searchService.index else { return nil }
            return "\(index.entries.count) files indexed"
        case .partial:
            guard let index = searchService.index else { return nil }
            return "\(index.entries.count) files indexed — directory may contain more files"
        case .error(let message):
            return message
        }
    }

    public var isIndexReady: Bool {
        searchService.index != nil
    }

    // MARK: - Search

    /// Debounced local search — runs 250 ms after the user pauses typing.
    /// Never touches Gemini.
    public func searchTextDidChange() {
        searchGeneration += 1
        let generation = searchGeneration
        debounceTask?.cancel()
        guard !searchText.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self, generation == self.searchGeneration else { return }
            self.runLocalSearch(keepAiMessage: true)
        }
    }

    /// Submit: immediate local search, then — when AI is enabled and
    /// configured — Gemini query interpretation with automatic fallback.
    public func submit() {
        debounceTask?.cancel()
        searchGeneration += 1
        aiTask?.cancel()
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }
        didSubmit = true
        isSearching = true
        runLocalSearch(keepAiMessage: false)

        guard let aiProvider, DirectorySearchSettings.isAIEnabled,
              DirectorySearchSettings.usesAIInterpretation, aiProvider.isConfigured else {
            aiMessage = aiProvider?.isConfigured == false && DirectorySearchSettings.isAIEnabled
                ? "AI unavailable — using local search"
                : nil
            return
        }

        let queryText = searchText
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let structured = try await aiProvider.interpret(query: queryText)
                guard !Task.isCancelled else { return }
                guard let index = self.searchService.index else { return }
                let refined = self.refinedQuery(local: self.localQuery(), ai: structured)
                if refined.hasStructuredFilters {
                    self.results = DirectorySearchEngine.search(index: index, query: refined)
                    self.aiMessage = "AI-assisted search — query interpreted by Gemini"
                } else {
                    // Gemini agreed with the local parse — keep local results.
                    self.aiMessage = nil
                }
            } catch is CancellationError {
                // A newer submit replaced this task.
            } catch {
                guard !Task.isCancelled else { return }
                // Gemini never breaks search: keep the local results.
                self.aiMessage = "AI unavailable — showing local search results"
            }
            self.isSearching = false
        }
    }

    /// Local parse of the current text (also the fallback intent).
    public func localQuery() -> DirectorySearchQuery {
        DirectoryQueryParser.parse(searchText)
    }

    /// Merges Gemini's interpretation with the local parse. Gemini wins for
    /// structured filters; text terms fall back to the local parse when
    /// Gemini returns none.
    private func refinedQuery(local: DirectorySearchQuery, ai: DirectorySearchQuery) -> DirectorySearchQuery {
        var query = ai
        if query.textTerms.isEmpty {
            query.textTerms = local.textTerms
        }
        if query.sort == .relevance && local.sort != .relevance {
            query.sort = local.sort
        }
        return query
    }

    private func runLocalSearch(keepAiMessage: Bool) {
        guard let index = searchService.index else {
            results = []
            isSearching = false
            aiMessage = keepAiMessage ? aiMessage : (isIndexReady ? nil : "Index is not ready yet")
            return
        }
        let query = localQuery()
        results = DirectorySearchEngine.search(index: index, query: query)
        isSearching = false
    }
}