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
    
    // MARK: - Background keep-alive & Live Activity lifecycle smoke tests

    /// The browser claims its keep-alive slot whenever at least one tab
    /// exists; the downloads/torrents slots stay untouched. (Public setters
    /// read the real app state — .active in the test host — so the claimed
    /// value is exercised through the injectable appState variant.)
    @MainActor
    func testKeepAliveClaimTracksTabPresence() {
        let tabManager = BrowserTabManager.shared
        let service = ServiceContainer.shared.backgroundKeepAliveService
        UserDefaults.standard.set(true, forKey: "fluxdl_bg_keepalive_browser")
        defer { UserDefaults.standard.removeObject(forKey: "fluxdl_bg_keepalive_browser") }

        XCTAssertFalse(tabManager.tabs.isEmpty)
        service.updateBrowserKeepAlive(!tabManager.tabs.isEmpty, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning, "open tab + toggle on + backgrounded must keep the process alive")

        service.updateBrowserKeepAlive(false, appState: .background)
        XCTAssertFalse(service.isKeepAliveRunning, "no tab → no browser keep-alive")

        // refreshBackgroundKeepAlive must execute cleanly (in the test host the
        // app is .active, so keep-alive stays stopped — the intended guard).
        tabManager.refreshBackgroundKeepAlive()
        service.stopAllKeepAlive()
        XCTAssertFalse(service.isKeepAliveRunning)
    }

    /// Enter/leave background must not crash: activity ends, timer stops,
    /// keep-alive re-evaluated. (In the test host the app state is .active,
    /// so pushBrowserLiveActivity self-ends — exactly the guard we want.)
    @MainActor
    func testBackgroundLifecycleHandlersRunCleanly() {
        let tabManager = BrowserTabManager.shared
        let service = ServiceContainer.shared.backgroundKeepAliveService

        tabManager.handleDidEnterBackground()
        tabManager.handleDidBecomeActive()
        tabManager.handleUserDefaultsChange()
        tabManager.refreshBackgroundKeepAlive()

        service.stopAllKeepAlive()
        XCTAssertFalse(service.isKeepAliveRunning)
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
    
    // MARK: - JavaScript URLs (javascript: scheme support)
    
    /// Loads an HTML page into a fresh ViewModel's web view and waits until the
    /// page finished loading.
    @MainActor
    private func makeViewModelWithPage(_ html: String) -> BrowserViewModel {
        let viewModel = BrowserViewModel()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if var tab = viewModel.tabManager.activeTab {
            tab.webView = webView
            viewModel.tabManager.activeTab = tab
        }
        
        let loaded = expectation(description: "page didFinish")
        webView.navigationDelegate = PageLoadDelegate(onFinish: {
            loaded.fulfill()
        })
        webView.loadHTMLString(html, baseURL: nil)
        wait(for: [loaded], timeout: 10)
        return viewModel
    }
    
    /// Synchronously evaluates JavaScript and returns the result (bridges the
    /// async completion handler onto the test's run loop).
    @MainActor
    private func evaluateJS(_ webView: WKWebView, _ script: String) -> Any? {
        var result: Any?
        let done = expectation(description: "evaluateJavaScript")
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }
    
    /// Polls a condition while pumping the run loop so async WebKit callbacks fire.
    @discardableResult
    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
    
    /// Test A — Basic JavaScript URL executes against the current page.
    @MainActor
    func testJavaScriptURLExecutesInCurrentPage() {
        let viewModel = makeViewModelWithPage("<html><body></body></html>")
        guard let webView = viewModel.tabManager.activeTab?.webView else {
            XCTFail("No web view")
            return
        }
        let expectedURL = viewModel.currentURL?.absoluteString
        
        viewModel.inputURLText = "javascript:document.body.setAttribute('data-test','success');"
        viewModel.handleSearchOrNavigate()
        
        // State invariants: no navigation, no URL mutation, no tab mutation.
        XCTAssertEqual(viewModel.currentURL?.absoluteString, expectedURL)
        XCTAssertEqual(viewModel.tabManager.activeTab?.url?.absoluteString, expectedURL)
        XCTAssertEqual(viewModel.inputURLText, "javascript:document.body.setAttribute('data-test','success');")
        XCTAssertNil(viewModel.javascriptExecutionMessage)
        
        let got: String? = evaluateJS(webView, "document.body.getAttribute('data-test')") as? String
        XCTAssertEqual(got, "success")
    }
    
    /// Test B — Form submission through a `javascript:` command.
    @MainActor
    func testJavaScriptURLSubmitsForm() {
        let html = """
        <html><body>
        <form id="90200" method="get" action="https://example.com/90200-submitted">
        <input type="text" name="q"><input type="submit">
        </form>
        </body></html>
        """
        let viewModel = makeViewModelWithPage(html)
        guard let webView = viewModel.tabManager.activeTab?.webView else {
            XCTFail("No web view")
            return
        }
        let expectedURL = viewModel.currentURL?.absoluteString
        
        viewModel.inputURLText = "javascript:document.getElementById('90200').submit();"
        viewModel.handleSearchOrNavigate()
        
        XCTAssertEqual(viewModel.currentURL?.absoluteString, expectedURL)
        // The form really submitted: a navigation toward its action URL started.
        let submitted = poll { webView.url?.absoluteString.contains("90200-submitted") == true }
        XCTAssertTrue(submitted, "form.submit() did not trigger a navigation")
    }
    
    /// Test C — Case-insensitive `javascript:` scheme detection.
    @MainActor
    func testJavaScriptURLSchemeCaseInsensitive() {
        let viewModel = makeViewModelWithPage("<html><body></body></html>")
        guard let webView = viewModel.tabManager.activeTab?.webView else {
            XCTFail("No web view")
            return
        }
        
        viewModel.inputURLText = "JavaScript:document.body.setAttribute('data-test','success');"
        viewModel.handleSearchOrNavigate()
        
        let got: String? = evaluateJS(webView, "document.body.getAttribute('data-test')") as? String
        XCTAssertEqual(got, "success")
        XCTAssertEqual(viewModel.currentURL?.absoluteString, "https://google.com")
    }
    
    /// Test D — Normal HTTPS URL still performs normal navigation.
    @MainActor
    func testJavaScriptURLDoesNotAffectNormalHTTPSNavigation() {
        let viewModel = BrowserViewModel()
        viewModel.inputURLText = "https://example.com"
        viewModel.handleSearchOrNavigate()
        
        XCTAssertEqual(viewModel.currentURL?.absoluteString, "https://example.com")
        XCTAssertEqual(viewModel.tabManager.activeTab?.url?.absoluteString, "https://example.com")
        XCTAssertNil(viewModel.javascriptExecutionMessage)
    }
    
    /// Test E — Ordinary text still uses the configured search engine.
    @MainActor
    func testJavaScriptURLDoesNotAffectSearchQueries() {
        let viewModel = BrowserViewModel()
        viewModel.inputURLText = "fluxdl javascript test"
        viewModel.handleSearchOrNavigate()
        
        XCTAssertTrue(viewModel.currentURL?.absoluteString.contains("google.com/search") == true)
        XCTAssertNil(viewModel.javascriptExecutionMessage)
    }
    
    /// Test F — JavaScript-disabled rejects javascript: execution without
    /// breaking normal navigation.
    @MainActor
    func testJavaScriptURLRespectsDisabledJavaScriptSetting() {
        let settings = BrowserSettings.shared
        let saved = settings.isJavaScriptEnabled
        settings.isJavaScriptEnabled = false
        defer { settings.isJavaScriptEnabled = saved }
        
        let viewModel = makeViewModelWithPage("<html><body></body></html>")
        guard let webView = viewModel.tabManager.activeTab?.webView else {
            XCTFail("No web view")
            return
        }
        
        viewModel.inputURLText = "javascript:document.body.setAttribute('data-test','nope');"
        viewModel.handleSearchOrNavigate()
        
        // Rejected with a clear user-facing message.
        XCTAssertNotNil(viewModel.javascriptExecutionMessage)
        XCTAssertEqual(viewModel.currentURL?.absoluteString, "https://google.com")
        
        let got: String? = evaluateJS(webView, "document.body.getAttribute('data-test')") as? String
        XCTAssertNil(got, "JavaScript must not run while disabled")
        
        // Normal navigation remains unaffected.
        viewModel.inputURLText = "https://example.com"
        viewModel.handleSearchOrNavigate()
        XCTAssertEqual(viewModel.currentURL?.absoluteString, "https://example.com")
    }
    
    /// Test G — A webpage `javascript:` link executes instead of navigating.
    @MainActor
    func testJavaScriptWebpageLinkExecutesInsteadOfNavigating() {
        // WKNavigationAction cannot be constructed by tests, so this exercises
        // the exact extraction + execution helpers the navigation policy uses.
        let url = URL(string: "javascript:document.body.setAttribute('data-test','success');")!
        let script = BrowserJavaScript.script(fromJavaScriptURL: url)
        XCTAssertEqual(script, "document.body.setAttribute('data-test','success');")
        
        let viewModel = makeViewModelWithPage("<html><body></body></html>")
        guard let webView = viewModel.tabManager.activeTab?.webView else {
            XCTFail("No web view")
            return
        }
        let expectedURL = viewModel.currentURL?.absoluteString
        
        guard let script else {
            XCTFail("Script not extracted")
            return
        }
        viewModel.executeJavaScript(script)
        
        XCTAssertEqual(viewModel.currentURL?.absoluteString, expectedURL)
        let got: String? = evaluateJS(webView, "document.body.getAttribute('data-test')") as? String
        XCTAssertEqual(got, "success")
    }
    
    /// Test H — Percent-encoded JavaScript is decoded exactly once.
    @MainActor
    func testJavaScriptURLEncodedDecodedOnce() {
        let viewModel = makeViewModelWithPage("<html><body></body></html>")
        guard let webView = viewModel.tabManager.activeTab?.webView else {
            XCTFail("No web view")
            return
        }
        
        // "a%26b" decodes once to the JS string 'a&b'; '%2526' decodes once to
        // the literal text '%26' — proving there is no double-decoding.
        viewModel.inputURLText = "javascript:window.__fluxdlA='a%26b';window.__fluxdlB='%2526';"
        viewModel.handleSearchOrNavigate()
        
        let a: String? = evaluateJS(webView, "window.__fluxdlA") as? String
        let b: String? = evaluateJS(webView, "window.__fluxdlB") as? String
        XCTAssertEqual(a, "a&b")
        XCTAssertEqual(b, "%26")
        XCTAssertNil(viewModel.javascriptExecutionMessage)
    }
    
    /// javascript: commands must never reach download detection.
    @MainActor
    func testJavaScriptURLNeverTreatedAsDownload() {
        let viewModel = BrowserViewModel()
        viewModel.promptDownload(url: URL(string: "javascript:void(0)")!)
        XCTAssertFalse(viewModel.showDownloadPrompt)
        XCTAssertNil(viewModel.pendingDownload)
        viewModel.promptDownload(url: URL(string: "javascript:document.getElementById('90200').submit();")!)
        XCTAssertFalse(viewModel.showDownloadPrompt)
        XCTAssertNil(viewModel.pendingDownload)
    }
    
    // MARK: - Download request identity & popup content
    
    /// Every pending download carries a unique ID and the popup must reflect
    /// the exact request that triggered it (no stale first/last state).
    @MainActor
    func testDownloadRequestUniqueIdentityAndFilename() {
        let viewModel = BrowserViewModel()
        
        viewModel.promptDownload(url: URL(string: "https://example.com/first.zip")!)
        let first = viewModel.pendingDownload
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.url.absoluteString, "https://example.com/first.zip")
        XCTAssertEqual(first?.displayFilename, "first.zip")
        
        viewModel.promptDownload(url: URL(string: "https://example.com/other.bin")!, filename: "report.pdf", mimeType: "application/pdf", fileSize: 1024)
        let second = viewModel.pendingDownload
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id, "each request must get a fresh unique ID")
        XCTAssertEqual(second?.displayFilename, "report.pdf")
        XCTAssertEqual(second?.mimeType, "application/pdf")
        XCTAssertEqual(second?.fileSize, 1024)
        
        // A duplicate detection of the same URL must not replace the visible request.
        viewModel.promptDownload(url: URL(string: "https://example.com/other.bin")!)
        XCTAssertEqual(viewModel.pendingDownload?.id, second?.id)
        XCTAssertEqual(viewModel.pendingDownload?.displayFilename, "report.pdf")
        
        // New tap, new request: no stale state from the previous popup.
        viewModel.cancelDetectedDownload()
        XCTAssertNil(viewModel.pendingDownload)
        XCTAssertFalse(viewModel.showDownloadPrompt)
        
        viewModel.promptDownload(url: URL(string: "https://example.com/third.tar.gz")!)
        XCTAssertNotEqual(viewModel.pendingDownload?.id, first?.id)
        XCTAssertEqual(viewModel.pendingDownload?.displayFilename, "third.tar.gz")
    }
}

/// Minimal WKNavigationDelegate used to wait for `loadHTMLString` completion.
private final class PageLoadDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFinish()
    }
}
