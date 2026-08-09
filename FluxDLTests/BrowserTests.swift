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
}
