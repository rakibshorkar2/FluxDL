import Foundation
import WebKit
import Combine

@MainActor
public final class BrowserTabManager: ObservableObject {
    public static let shared = BrowserTabManager()
    
    @Published public var tabs: [BrowserTabModel] = []
    @Published public var activeTabId: UUID = UUID()
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

        if tabToClose.isPrivate {
            // Incognito tabs never land in "recently closed" and their
            // website data is wiped immediately.
            wipePrivateWebData(of: tabToClose)
        } else {
            // Save to recently closed (keep last 10)
            recentlyClosedTabs.insert(tabToClose, at: 0)
            if recentlyClosedTabs.count > 10 {
                recentlyClosedTabs.removeLast()
            }
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
        for tab in tabs where tab.isPrivate {
            wipePrivateWebData(of: tab)
        }
        let restorable = tabs.filter { !$0.isPrivate }
        recentlyClosedTabs.append(contentsOf: restorable)
        if recentlyClosedTabs.count > 10 {
            recentlyClosedTabs = Array(recentlyClosedTabs.prefix(10))
        }
        let fallback = BrowserTabModel(title: "Google", url: URL(string: "https://google.com"))
        tabs = [fallback]
        activeTabId = fallback.id
        hapticService.impactOccurred(.medium)
        persistSession()
    }

    /// Closes every tab except the one with `id`.
    public func closeOtherTabs(keeping id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        for tab in tabs where tab.id != id {
            if tab.isPrivate {
                wipePrivateWebData(of: tab)
            }
        }
        let kept = tabs.filter { $0.id == id }
        let restorable = tabs.filter { $0.id != id && !$0.isPrivate }
        recentlyClosedTabs.insert(contentsOf: restorable, at: 0)
        if recentlyClosedTabs.count > 10 {
            recentlyClosedTabs = Array(recentlyClosedTabs.prefix(10))
        }
        tabs = kept
        activeTabId = id
        hapticService.impactOccurred(.medium)
        persistSession()
    }

    /// Immediately clears cookies/cache for a closed private tab's web view.
    private func wipePrivateWebData(of tab: BrowserTabModel) {
        guard let store = tab.webView?.configuration.websiteDataStore else { return }
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// Persists the current tab list so it can be restored on next launch.
    /// Private tabs are never persisted — they only exist for this session.
    private func persistSession() {
        let restorable = tabs.filter { !$0.isPrivate }
        guard !restorable.isEmpty else {
            BrowserTabPersistence.shared.clear()
            return
        }
        let activeID = restorable.contains(where: { $0.id == activeTabId }) ? activeTabId : restorable[0].id
        BrowserTabPersistence.shared.save(tabs: restorable, activeTabId: activeID)
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
