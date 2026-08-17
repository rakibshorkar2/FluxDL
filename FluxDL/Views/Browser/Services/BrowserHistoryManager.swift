import Foundation
import Combine

@MainActor
public final class BrowserHistoryManager: ObservableObject {
    public static let shared = BrowserHistoryManager()
    
    @Published public private(set) var historyItems: [BrowserHistoryItem] = []
    
    private let storageKey = "fluxdl_browser_history"
    
    private init() {
        loadHistory()
    }
    
    public func addHistory(title: String, urlString: String) {
        guard !urlString.isEmpty, urlString != "about:blank" else { return }
        
        // Remove duplicate if it exists recently
        historyItems.removeAll { $0.urlString == urlString }
        
        let item = BrowserHistoryItem(title: title.isEmpty ? urlString : title, urlString: urlString)
        historyItems.insert(item, at: 0)
        
        // Limit total history entries to 500
        if historyItems.count > 500 {
            historyItems = Array(historyItems.prefix(500))
        }
        
        saveHistory()
    }
    
    public func deleteEntry(id: UUID) {
        historyItems.removeAll { $0.id == id }
        saveHistory()
    }
    
    public func clearAllHistory() {
        historyItems.removeAll()
        saveHistory()
    }
    
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(historyItems) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let items = try? JSONDecoder().decode([BrowserHistoryItem].self, from: data) {
            self.historyItems = items
        }
    }
}
