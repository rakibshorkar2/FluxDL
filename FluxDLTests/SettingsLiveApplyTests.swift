import XCTest
@testable import FluxDL

/// Verifies that settings written directly to UserDefaults by the Settings
/// tab's @AppStorage toggles are re-applied to the live in-memory service
/// state without an app restart (the "no cosmetic toggle" requirement).
final class SettingsLiveApplyTests: XCTestCase {

    private let maxConcurrentKey = "fluxdl_max_concurrent_downloads"
    private let autoRetryKey = "fluxdl_auto_retry_enabled"
    private let wifiOnlyKey = "fluxdl_wifi_only"
    private let bandwidthKey = "fluxdl_bandwidth_limit"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: maxConcurrentKey)
        UserDefaults.standard.removeObject(forKey: autoRetryKey)
        UserDefaults.standard.removeObject(forKey: wifiOnlyKey)
        UserDefaults.standard.removeObject(forKey: bandwidthKey)
        super.tearDown()
    }

    // MARK: - QueueManager (Concurrent Downloads / Auto-Retry)

    @MainActor
    func testQueueManagerResyncsMaxConcurrentFromSettings() {
        let queueManager = QueueManager()

        UserDefaults.standard.set(6, forKey: maxConcurrentKey)
        queueManager.handleUserDefaultsChange()

        XCTAssertEqual(queueManager.maxConcurrentDownloads, 6,
                       "Settings change to Concurrent Downloads must reach the live queue manager")
    }

    @MainActor
    func testQueueManagerResyncsAutoRetryFromSettings() {
        let queueManager = QueueManager()

        UserDefaults.standard.set(false, forKey: autoRetryKey)
        queueManager.handleUserDefaultsChange()

        XCTAssertFalse(queueManager.autoRetryEnabled,
                       "Settings change to Auto-Retry must reach the live queue manager")
    }

    // MARK: - PowerNetworkMonitor (Wi-Fi Only / Bandwidth)

    @MainActor
    func testPowerNetworkMonitorResyncsWiFiOnlyFromSettings() {
        let monitor = PowerNetworkMonitor()
        XCTAssertFalse(monitor.isWiFiOnlyEnabled)

        UserDefaults.standard.set(true, forKey: wifiOnlyKey)
        monitor.handleUserDefaultsChange()

        XCTAssertTrue(monitor.isWiFiOnlyEnabled,
                      "Settings change to Wi-Fi Only must reach the live monitor")
    }

    @MainActor
    func testPowerNetworkMonitorResyncsBandwidthFromSettings() {
        let monitor = PowerNetworkMonitor()

        UserDefaults.standard.set(512, forKey: bandwidthKey)
        monitor.handleUserDefaultsChange()

        XCTAssertEqual(monitor.bandwidthLimitKBps, 512,
                       "Settings change to Bandwidth Limiter must reach the live monitor")
    }
}
