import XCTest
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
}
