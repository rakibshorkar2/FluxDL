import Foundation
import Combine

/// One directory-mode history entry. Kept strictly separate from the Web
/// Browser's history (`BrowserHistoryManager` / `fluxdl_browser_history`).
public struct DirectoryHistoryEntry: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let urlString: String
    public let visitDate: Date

    public init(id: UUID = UUID(), title: String, urlString: String, visitDate: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.visitDate = visitDate
    }
}

/// Persists directory-mode history under its own UserDefaults key so it
/// never mixes with web browsing history.
@MainActor
public final class DirectoryHistoryManager: ObservableObject {

    public static let shared = DirectoryHistoryManager()

    @Published public private(set) var historyItems: [DirectoryHistoryEntry] = []

    private let storageKey = "fluxdl_directory_history"
    private let capacity = 500

    public init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: storageKey),
           let items = try? JSONDecoder().decode([DirectoryHistoryEntry].self, from: data) {
            historyItems = items
        }
    }

    public func addHistory(title: String, urlString: String) {
        if let index = historyItems.firstIndex(where: { $0.urlString == urlString }) {
            historyItems.remove(at: index)
        }
        historyItems.insert(DirectoryHistoryEntry(title: title, urlString: urlString), at: 0)
        if historyItems.count > capacity {
            historyItems = Array(historyItems.prefix(capacity))
        }
        persist()
    }

    public func deleteEntry(id: UUID) {
        historyItems.removeAll { $0.id == id }
        persist()
    }

    public func clearAllHistory() {
        historyItems.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(historyItems) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}