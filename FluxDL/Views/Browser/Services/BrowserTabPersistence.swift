import Foundation

/// Persists browser tab state (URLs, titles, ordering) so sessions can be
/// restored across launches. Web view instances are never stored.
public final class BrowserTabPersistence {
    public static let shared = BrowserTabPersistence()
    
    private let storageKey = "fluxdl_browser_tab_snapshots"
    private let settingsKey = "browser_restore_tabs"
    
    private init() {}
    
    /// Whether tab restoration is enabled via user settings.
    public var isRestoreEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) != nil
            ? UserDefaults.standard.bool(forKey: settingsKey) : true
    }
    
    /// Saves the current tab list, preserving the last active tab.
    public func save(tabs: [BrowserTabModel], activeTabId: UUID) {
        guard !tabs.isEmpty else { return }
        let payload = PersistedTabs(activeTabId: activeTabId, tabs: tabs.map { $0.snapshot() })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
    
    /// Loads the previously saved session, or nil when nothing is stored.
    public func load() -> PersistedTabs? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PersistedTabs.self, from: data)
    }
    
    public func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

public struct PersistedTabs: Codable {
    public let activeTabId: UUID
    public let tabs: [BrowserTabModel.Snapshot]
    
    public init(activeTabId: UUID, tabs: [BrowserTabModel.Snapshot]) {
        self.activeTabId = activeTabId
        self.tabs = tabs
    }
}
