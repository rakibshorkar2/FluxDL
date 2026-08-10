import Foundation
import WebKit
import Combine

@MainActor
public final class BrowserTabManager: ObservableObject {
    public static let shared = BrowserTabManager()
    
    @Published public var tabs: [BrowserTabModel] = []
    @Published public var activeTabId: UUID
    @Published public var recentlyClosedTabs: [BrowserTabModel] = []
    @Published public var isTabGridPresented: Bool = false
    
    // Shared WKProcessPool for memory efficiency & session sharing
    public let sharedProcessPool = WKProcessPool()
    public let hapticService: HapticServiceProtocol = ServiceContainer.shared.hapticService
    
    private init() {
        // Restore previous session when enabled and available.
        if BrowserTabPersistence.shared.isRestoreEnabled,
           let persisted = BrowserTabPersistence.shared.load(),
           !persisted.tabs.isEmpty {
            self.tabs = persisted.tabs.map { BrowserTabModel(snapshot: $0) }
            let restoredID = persisted.activeTabId
            if self.tabs.contains(where: { $0.id == restoredID }) {
                self.activeTabId = restoredID
            } else {
                self.activeTabId = self.tabs[0].id
            }
            return
        }
        
        let initialTab = BrowserTabModel(title: "Google", url: URL(string: "https://google.com"))
        self.tabs = [initialTab]
        self.activeTabId = initialTab.id
    }
    
    public var activeTab: BrowserTabModel? {
        get { tabs.first(where: { $0.id == activeTabId }) }
        set {
            if let newValue = newValue, let idx = tabs.firstIndex(where: { $0.id == newValue.id }) {
                tabs[idx] = newValue
            }
        }
    }
    
    public func createNewTab(url: URL? = nil, isPrivate: Bool = false) -> UUID {
        let targetURL = url ?? URL(string: BrowserSettings.shared.homepage) ?? URL(string: "https://google.com")!
        var newTab = BrowserTabModel(title: "New Tab", url: targetURL, isPrivate: isPrivate)
        newTab.inputURLText = targetURL.absoluteString
        tabs.append(newTab)
        activeTabId = newTab.id
        
        hapticService.impactOccurred(.light)
        persistSession()
        pruneInactiveTabsIfNeeded()
        return newTab.id
    }
    
    public func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tabToClose = tabs[idx]
        
        // Save to recently closed (keep last 10)
        recentlyClosedTabs.insert(tabToClose, at: 0)
        if recentlyClosedTabs.count > 10 {
            recentlyClosedTabs.removeLast()
        }
        
        tabs.remove(at: idx)
        
        if tabs.isEmpty {
            let fallback = BrowserTabModel(title: "Google", url: URL(string: "https://google.com"))
            tabs = [fallback]
            activeTabId = fallback.id
        } else if activeTabId == id {
            let nextIndex = min(idx, tabs.count - 1)
            activeTabId = tabs[nextIndex].id
        }
        
        persistSession()
    }
    
    /// Closes the tab owning the given web view instance (e.g. window.close()).
    public func closeTab(webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        closeTab(id: tab.id)
    }
    
    public func duplicateTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        _ = createNewTab(url: tab.url, isPrivate: tab.isPrivate)
    }
    
    public func restoreLastClosedTab() {
        guard !recentlyClosedTabs.isEmpty else { return }
        let restored = recentlyClosedTabs.removeFirst()
        var newTab = BrowserTabModel(title: restored.title, url: restored.url, isPrivate: restored.isPrivate)
        newTab.inputURLText = restored.inputURLText
        tabs.append(newTab)
        activeTabId = newTab.id
        hapticService.impactOccurred(.medium)
        persistSession()
    }
    
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
        if let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx].lastActiveDate = Date()
        }
        hapticService.selectionChanged()
        persistSession()
    }
    
    /// Reorders tabs via a drag-and-drop move operation from `source` to `destination`.
    public func moveTab(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first, sourceIndex != destination else { return }
        let movedTab = tabs.remove(at: sourceIndex)
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        tabs.insert(movedTab, at: adjustedDestination)
        hapticService.selectionChanged()
        persistSession()
    }
    
    /// Removes all tabs and starts fresh with a single home tab.
    public func closeAllTabs() {
        recentlyClosedTabs.append(contentsOf: tabs)
        if recentlyClosedTabs.count > 10 {
            recentlyClosedTabs = Array(recentlyClosedTabs.prefix(10))
        }
        let fallback = BrowserTabModel(title: "Google", url: URL(string: "https://google.com"))
        tabs = [fallback]
        activeTabId = fallback.id
        hapticService.impactOccurred(.medium)
        persistSession()
    }
    
    /// Persists the current tab list so it can be restored on next launch.
    private func persistSession() {
        BrowserTabPersistence.shared.save(tabs: tabs, activeTabId: activeTabId)
    }
    
    /// Memory optimization: suspend web views for inactive tabs when tab count > 5
    private func pruneInactiveTabsIfNeeded() {
        guard tabs.count > 5 else { return }
        
        // Keep active tab + 3 most recently active tabs in RAM
        let sortedIndices = tabs.indices.sorted { tabs[$0].lastActiveDate > tabs[$1].lastActiveDate }
        for (rank, index) in sortedIndices.enumerated() {
            if rank > 3 && tabs[index].id != activeTabId {
                // Relinquish web view reference to release memory
                tabs[index].webView = nil
            }
        }
    }
}
