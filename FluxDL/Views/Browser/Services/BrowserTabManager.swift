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
    
    private init() {
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
    }
    
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
        if let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx].lastActiveDate = Date()
        }
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
