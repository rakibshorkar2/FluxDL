import XCTest
import UIKit
@testable import FluxDL

final class BackgroundKeepAliveTests: XCTestCase {

    private let downloadsKey = "fluxdl_bg_keepalive_downloads"
    private let browserKey = "fluxdl_bg_keepalive_browser"
    private let torrentsKey = "fluxdl_bg_keepalive_torrents"

    override func tearDown() {
        // Restore the user's real preferences so tests never leak state.
        UserDefaults.standard.removeObject(forKey: downloadsKey)
        UserDefaults.standard.removeObject(forKey: browserKey)
        UserDefaults.standard.removeObject(forKey: torrentsKey)
        super.tearDown()
    }

    func testBackgroundServiceStop() {
        let service = BackgroundKeepAliveService()
        service.stopAllKeepAlive()
        XCTAssertFalse(service.isKeepAliveRunning)
    }

    /// Foreground is never a keep-alive scenario: iOS keeps foreground
    /// processes alive natively, and running audio/GPS wastes battery.
    func testForegroundNeverKeepsAlive() {
        let service = BackgroundKeepAliveService()
        service.updateDownloadsKeepAlive(true, appState: .active)
        service.updateBrowserKeepAlive(true, appState: .active)
        service.updateTorrentsKeepAlive(true, appState: .active)
        XCTAssertFalse(service.isKeepAliveRunning)
    }

    /// Each subsystem's claim is independent: a downloads claim while a
    /// browser claim exists must not cancel it, and vice versa.
    func testClaimsAreIndependentAndMerge() {
        let service = BackgroundKeepAliveService()

        UserDefaults.standard.set(true, forKey: browserKey)
        UserDefaults.standard.set(true, forKey: downloadsKey)
        UserDefaults.standard.set(true, forKey: torrentsKey)

        // Downloads-only claim keeps the process alive.
        service.updateDownloadsKeepAlive(true, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning)

        // A download tick while the browser is claiming must not cancel it.
        service.updateBrowserKeepAlive(true, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning)
        service.updateDownloadsKeepAlive(false, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning, "browser claim must survive a downloads release")

        // Torrents claim joins and survives the browser releasing.
        service.updateTorrentsKeepAlive(true, appState: .background)
        service.updateBrowserKeepAlive(false, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning, "torrent claim must survive a browser release")

        // Browser re-claims while torrents are still active.
        service.updateBrowserKeepAlive(true, appState: .background)
        service.updateTorrentsKeepAlive(false, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning, "browser claim must survive a torrent release")
    }

    /// No claims at all (backgrounded) must stop keep-alive.
    func testNoClaimsStopsKeepAlive() {
        let service = BackgroundKeepAliveService()
        service.updateDownloadsKeepAlive(true, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning)

        service.updateDownloadsKeepAlive(false, appState: .background)
        service.updateBrowserKeepAlive(false, appState: .background)
        service.updateTorrentsKeepAlive(false, appState: .background)
        XCTAssertFalse(service.isKeepAliveRunning)
    }

    /// The keep-alive toggle must gate the browser claim: claim true + toggle
    /// off → no keep-alive, even while backgrounded.
    func testBrowserToggleDisablesBrowserKeepAlive() {
        let service = BackgroundKeepAliveService()
        UserDefaults.standard.set(false, forKey: browserKey)
        UserDefaults.standard.set(true, forKey: downloadsKey)

        service.updateBrowserKeepAlive(true, appState: .background)
        XCTAssertFalse(service.isKeepAliveRunning, "browser keep-alive toggle off must block the claim")

        // The downloads slot is unaffected by the browser toggle.
        service.updateDownloadsKeepAlive(true, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning)
    }

    /// Downloads and torrents defaults are TRUE when absent; browser default is FALSE.
    func testToggleDefaults() {
        let service = BackgroundKeepAliveService()
        UserDefaults.standard.removeObject(forKey: downloadsKey)
        UserDefaults.standard.removeObject(forKey: browserKey)
        UserDefaults.standard.removeObject(forKey: torrentsKey)

        // Absent downloads key → enabled by default.
        service.updateDownloadsKeepAlive(true, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning)
        service.updateDownloadsKeepAlive(false, appState: .background)

        // Absent browser key → DISABLED by default (browser keep-alive is opt-in).
        service.updateBrowserKeepAlive(true, appState: .background)
        XCTAssertFalse(service.isKeepAliveRunning)
        service.updateBrowserKeepAlive(false, appState: .background)

        // Absent torrents key → enabled by default.
        service.updateTorrentsKeepAlive(true, appState: .background)
        XCTAssertTrue(service.isKeepAliveRunning)
    }
}