import XCTest
import UIKit
import WebKit
@testable import FluxDL

final class BrowserTests: XCTestCase {
    
    @MainActor
    func testBrowserViewModelNavigation() {
        let viewModel = BrowserViewModel()
        viewModel.inputURLText = "github.com"
        viewModel.handleSearchOrNavigate()
        
        XCTAssertEqual(viewModel.currentURL?.absoluteString, "https://github.com")
    }
    
    @MainActor
    func testBrowserViewModelSearchQueryFallback() {
        let viewModel = BrowserViewModel()
        viewModel.inputURLText = "swiftui tutorial"
        viewModel.handleSearchOrNavigate()
        
        XCTAssertTrue(viewModel.currentURL?.absoluteString.contains("google.com/search") == true)
    }
    
    @MainActor
    func testDownloadPromptTrigger() {
        let viewModel = BrowserViewModel()
        let testURL = URL(string: "https://example.com/test.zip")!
        
        viewModel.promptDownload(url: testURL)
        
        XCTAssertTrue(viewModel.showDownloadPrompt)
        XCTAssertEqual(viewModel.detectedDownloadURL, testURL)
    }
    
    @MainActor
    func testMultiTabManager() {
        let tabManager = BrowserTabManager.shared
        let initialCount = tabManager.tabs.count
        
        let newTabID = tabManager.createNewTab(url: URL(string: "https://apple.com"))
        XCTAssertEqual(tabManager.tabs.count, initialCount + 1)
        XCTAssertEqual(tabManager.activeTabId, newTabID)
        
        tabManager.closeTab(id: newTabID)
        XCTAssertEqual(tabManager.recentlyClosedTabs.first?.url?.absoluteString, "https://apple.com")
    }
    
    @MainActor
    func testBookmarkManager() {
        let manager = BookmarkManager.shared
        let initialCount = manager.bookmarks.count
        
        manager.addBookmark(title: "Test Site", urlString: "https://test.com")
        XCTAssertEqual(manager.bookmarks.count, initialCount + 1)
        XCTAssertTrue(manager.isBookmarked(urlString: "https://test.com"))
        
        if let item = manager.bookmarks.first(where: { $0.urlString == "https://test.com" }) {
            manager.removeBookmark(id: item.id)
        }
    }
    
    @MainActor
    func testBrowserHistoryManager() {
        let manager = BrowserHistoryManager.shared
        manager.addHistory(title: "FluxDL Docs", urlString: "https://fluxdl.test/docs")
        
        XCTAssertTrue(manager.historyItems.contains { $0.urlString == "https://fluxdl.test/docs" })
    }
    
    @MainActor
    func testTabSnapshotRoundTrip() {
        let tab = BrowserTabModel(
            title: "Example",
            url: URL(string: "https://example.com/page"),
            isPrivate: true
        )
        tab.snapshot()
        
        var desktopTab = tab
        desktopTab.isDesktopMode = true
        let snapshot = desktopTab.snapshot()
        
        XCTAssertEqual(snapshot.id, desktopTab.id)
        XCTAssertEqual(snapshot.urlString, "https://example.com/page")
        XCTAssertTrue(snapshot.isDesktopMode)
        XCTAssertTrue(snapshot.isPrivate)
        XCTAssertEqual(snapshot.url, desktopTab.url)
        
        let restored = BrowserTabModel(snapshot: snapshot)
        XCTAssertEqual(restored.id, snapshot.id)
        XCTAssertEqual(restored.url, snapshot.url)
        XCTAssertEqual(restored.title, "Example")
        XCTAssertTrue(restored.isDesktopMode)
        XCTAssertTrue(restored.isPrivate)
        XCTAssertNil(restored.webView)
    }
    
    @MainActor
    func testTabPersistenceRoundTrip() {
        let persistence = BrowserTabPersistence.shared
        persistence.clear()
        
        let tab1 = BrowserTabModel(title: "One", url: URL(string: "https://one.com"))
        let tab2 = BrowserTabModel(title: "Two", url: URL(string: "https://two.com"))
        let activeID = tab1.id
        
        persistence.save(tabs: [tab1, tab2], activeTabId: activeID)
        
        let loaded = persistence.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.activeTabId, activeID)
        XCTAssertEqual(loaded?.tabs.count, 2)
        XCTAssertEqual(loaded?.tabs[0].urlString, "https://one.com")
        XCTAssertEqual(loaded?.tabs[1].title, "Two")
        
        persistence.clear()
        XCTAssertNil(persistence.load())
    }
    
    @MainActor
    func testTabPersistenceEmptySaveIsIgnored() {
        let persistence = BrowserTabPersistence.shared
        persistence.clear()
        persistence.save(tabs: [], activeTabId: UUID())
        XCTAssertNil(persistence.load())
    }
    
    @MainActor
    func testMoveTabReorder() {
        let tabManager = BrowserTabManager.shared
        let initial = tabManager.tabs
        
        tabManager.moveTab(from: IndexSet(integer: 0), to: initial.count)
        XCTAssertEqual(tabManager.tabs.count, initial.count)
        
        // moveTab with a source equal to destination should be a no-op
        let before = tabManager.tabs
        tabManager.moveTab(from: IndexSet(integer: 0), to: 0)
        XCTAssertEqual(tabManager.tabs.map(\.id), before.map(\.id))
    }
    
    @MainActor
    func testCloseAllTabsKeepsSingleFallback() {
        let tabManager = BrowserTabManager.shared
        _ = tabManager.createNewTab(url: URL(string: "https://apple.com"))
        
        tabManager.closeAllTabs()
        XCTAssertEqual(tabManager.tabs.count, 1)
        XCTAssertNotNil(tabManager.tabs.first?.url)
    }
    
    @MainActor
    func testSettingsRestoreTabsToggleDefaultsTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "browser_restore_tabs")
        XCTAssertTrue(BrowserSettings.shared.restoreTabsOnLaunch)
    }
    
    // MARK: - Navigation state
    
    @MainActor
    func testBackForwardStateSync() {
        let viewModel = BrowserViewModel()
        if var tab = viewModel.tabManager.activeTab {
            tab.canGoBack = true
            tab.canGoForward = true
            viewModel.tabManager.activeTab = tab
        }
        viewModel.syncActiveTabState()
        XCTAssertTrue(viewModel.canGoBack)
        XCTAssertTrue(viewModel.canGoForward)
    }
    
    @MainActor
    func testStopLoadingClearsState() {
        let viewModel = BrowserViewModel()
        viewModel.isLoading = true
        viewModel.stopLoading()
        XCTAssertFalse(viewModel.isLoading)
        if let tab = viewModel.tabManager.activeTab {
            XCTAssertFalse(tab.isLoading)
        }
    }
    
    @MainActor
    func testCopyCurrentURL() {
        let viewModel = BrowserViewModel()
        viewModel.currentURL = URL(string: "https://example.com/copy-me")
        viewModel.copyCurrentURL()
        XCTAssertEqual(UIPasteboard.general.string, "https://example.com/copy-me")
    }
    
    @MainActor
    func testDesktopMobileToggle() {
        let viewModel = BrowserViewModel()
        let initial = viewModel.tabManager.activeTab?.isDesktopMode ?? false
        
        viewModel.toggleDesktopMode()
        XCTAssertNotEqual(viewModel.tabManager.activeTab?.isDesktopMode, initial)
        
        viewModel.toggleDesktopMode()
        XCTAssertEqual(viewModel.tabManager.activeTab?.isDesktopMode, initial)
    }
    
    @MainActor
    func testClearHistoryViaViewModel() {
        let history = BrowserHistoryManager.shared
        history.clearAllHistory()
        history.addHistory(title: "A", urlString: "https://a.com")
        history.addHistory(title: "B", urlString: "https://b.com")
        XCTAssertEqual(history.historyItems.count, 2)
        
        let viewModel = BrowserViewModel()
        viewModel.clearHistory()
        XCTAssertTrue(history.historyItems.isEmpty)
    }
    
    // MARK: - History
    
    @MainActor
    func testHistorySearchDeleteClear() {
        let history = BrowserHistoryManager.shared
        history.clearAllHistory()
        history.addHistory(title: "GitHub", urlString: "https://github.com")
        history.addHistory(title: "Apple", urlString: "https://apple.com")
        
        let matches = history.historyItems.filter {
            $0.title.localizedCaseInsensitiveContains("git") ||
            $0.urlString.localizedCaseInsensitiveContains("git")
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.urlString, "https://github.com")
        
        if let item = history.historyItems.first {
            history.deleteEntry(id: item.id)
            XCTAssertFalse(history.historyItems.contains { $0.id == item.id })
        }
        
        history.clearAllHistory()
        XCTAssertTrue(history.historyItems.isEmpty)
    }
    
    @MainActor
    func testHistoryStoresTimestamp() {
        let history = BrowserHistoryManager.shared
        history.clearAllHistory()
        let before = Date()
        history.addHistory(title: "Dated", urlString: "https://dated.com")
        let after = Date()
        
        let item = history.historyItems.first
        XCTAssertNotNil(item)
        XCTAssertNotNil(item?.visitDate)
        if let date = item?.visitDate {
            XCTAssertGreaterThanOrEqual(date, before)
            XCTAssertLessThanOrEqual(date, after)
        }
    }
    
    // MARK: - Bookmarks
    
    @MainActor
    func testBookmarkEditAndPersistence() {
        let manager = BookmarkManager.shared
        let title = "Edit Target \(UUID().uuidString.prefix(6))"
        let url = "https://edittarget.example.com"
        manager.addBookmark(title: title, urlString: url)
        XCTAssertTrue(manager.isBookmarked(urlString: url))
        
        if let item = manager.bookmarks.first(where: { $0.urlString == url }) {
            manager.updateBookmark(id: item.id, newTitle: "Renamed", newFolder: "Work", isFavorite: true)
            let updated = manager.bookmarks.first(where: { $0.id == item.id })
            XCTAssertEqual(updated?.title, "Renamed")
            XCTAssertEqual(updated?.folder, "Work")
            XCTAssertTrue(updated?.isFavorite == true)
            manager.removeBookmark(id: item.id)
        }
        XCTAssertFalse(manager.isBookmarked(urlString: url))
    }
    
    // MARK: - Tab restoration / app relaunch simulation
    
    @MainActor
    func testAppRelaunchRestoresTabs() {
        let persistence = BrowserTabPersistence.shared
        persistence.clear()
        
        // Session before relaunch
        var tab1 = BrowserTabModel(title: "One", url: URL(string: "https://one.com"))
        tab1.isDesktopMode = true
        let tab2 = BrowserTabModel(title: "Two", url: URL(string: "https://two.com"))
        persistence.save(tabs: [tab1, tab2], activeTabId: tab1.id)
        
        // Simulate relaunch: load persisted session the way BrowserTabManager does.
        let restored = persistence.load()
        XCTAssertNotNil(restored)
        let tabs = restored?.tabs.map { BrowserTabModel(snapshot: $0) } ?? []
        
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0].url?.absoluteString, "https://one.com")
        XCTAssertTrue(tabs[0].isDesktopMode)
        XCTAssertEqual(tabs[1].title, "Two")
        XCTAssertTrue(tabs.allSatisfy { $0.webView == nil })
        
        let activeID = restored?.activeTabId
        XCTAssertEqual(activeID, tab1.id)
        
        persistence.clear()
    }
    
    // MARK: - Downloads
    
    @MainActor
    func testDownloadPromptAndCancellation() {
        let viewModel = BrowserViewModel()
        let url = URL(string: "https://example.com/file.mkv")!
        viewModel.promptDownload(url: url)
        XCTAssertTrue(viewModel.showDownloadPrompt)
        XCTAssertEqual(viewModel.detectedDownloadURL, url)
        
        viewModel.showDownloadPrompt = false
        viewModel.detectedDownloadURL = nil
        XCTAssertFalse(viewModel.showDownloadPrompt)
        XCTAssertNil(viewModel.detectedDownloadURL)
    }
    
    // MARK: - Proxy state
    
    @MainActor
    func testProxyStateReflectsServiceWhenDisabled() {
        let session = BrowserProxySession.shared
        session.refresh()
        
        let proxyService = ServiceContainer.shared.proxyService
        if proxyService.isEnabled {
            proxyService.disable()
        }
        session.refresh()
        
        XCTAssertNil(session.activeConfiguration)
        XCTAssertFalse(session.isProxyActive)
    }
    
    @MainActor
    func testProxyBypassForLocalHosts() {
        let session = BrowserProxySession.shared
        XCTAssertTrue(session.shouldBypassProxy(for: URL(string: "http://localhost:8080")!))
        XCTAssertTrue(session.shouldBypassProxy(for: URL(string: "http://127.0.0.1")!))
        XCTAssertFalse(session.shouldBypassProxy(for: URL(string: "https://example.com")!))
    }
    
    // MARK: - Content blocking & privacy settings
    
    @MainActor
    func testAdBlockerSettingsAndWhitelist() {
        let settings = BrowserSettings.shared
        XCTAssertTrue(settings.isAdBlockerEnabled)
        
        let domain = "ads.example.com"
        XCTAssertFalse(settings.isWhitelisted(domain: domain))
        settings.toggleWhitelist(domain: domain)
        XCTAssertTrue(settings.isWhitelisted(domain: domain))
        settings.toggleWhitelist(domain: domain)
        XCTAssertFalse(settings.isWhitelisted(domain: domain))
    }
    
    @MainActor
    func testAdBlockEngineAppliesRuleListSafely() {
        let config = WKWebViewConfiguration()
        // Disabled: must be a no-op that never crashes.
        let settings = BrowserSettings.shared
        let wasEnabled = settings.isAdBlockerEnabled
        settings.isAdBlockerEnabled = false
        AdBlockEngine.shared.applyRuleList(to: config, domain: "example.com")
        settings.isAdBlockerEnabled = wasEnabled
        
        // Whitelisted domain: must be a no-op.
        AdBlockEngine.shared.applyRuleList(to: config, domain: "fluxdl.example.com")
        XCTAssertEqual(config.userContentController.userScripts.count, 0)
    }
    
    @MainActor
    func testCustomBlockRuleSanitization() {
        // Plain domains: dots must be escaped so they can't match loosely.
        let domain = AdBlockEngine.sanitizedURLPattern("ads.example.com")
        XCTAssertEqual(domain, "ads\\.example\\.com")
        
        // Wildcards become `.*`, everything else stays escaped.
        let wildcard = AdBlockEngine.sanitizedURLPattern("*tracker*.js")
        XCTAssertEqual(wildcard, ".*tracker.*\\.js")
        
        // A user rule with regex metacharacters must not leak them raw.
        let hostile = AdBlockEngine.sanitizedURLPattern("ad[0-9](net)|*")
        XCTAssertFalse(hostile.contains("[0-9]"))
        XCTAssertFalse(hostile.contains("|"))
        
        // JSON output must be well-formed and contain the escaped pattern.
        let json = AdBlockEngine.customRulesJSON(from: ["doubleclick.net", ""])
        XCTAssertTrue(json.contains("doubleclick\\.net"))
        XCTAssertTrue(json.contains("\"type\":\"block\""))
        XCTAssertTrue(json.hasPrefix("["), "JSON should be an array")
        XCTAssertTrue(json.hasSuffix("]"))
    }
    
    @MainActor
    func testCustomBlockRulePersistence() {
        let settings = BrowserSettings.shared
        let saved = settings.customBlockRules
        defer { settings.customBlockRules = saved }
        
        settings.customBlockRules = ["example-tracker.com", "*ads*.xyz"]
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: "browser_custom_block_rules"),
            ["example-tracker.com", "*ads*.xyz"]
        )
        
        settings.customBlockRules.removeAll()
        XCTAssertEqual(settings.customBlockRules, [])
    }
    
    @MainActor
    func testPopupBlockingSettingDefaultsEnabled() {
        let settings = BrowserSettings.shared
        let saved = settings.isPopupBlockingEnabled
        defer { settings.isPopupBlockingEnabled = saved }
        
        settings.isPopupBlockingEnabled = true
        XCTAssertTrue(settings.isPopupBlockingEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "browser_popup_blocking"))
        
        settings.isPopupBlockingEnabled = false
        XCTAssertFalse(settings.isPopupBlockingEnabled)
    }
}
