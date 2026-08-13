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
    private let lowBatteryPauseKey = "fluxdl_low_battery_pause"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: maxConcurrentKey)
        UserDefaults.standard.removeObject(forKey: autoRetryKey)
        UserDefaults.standard.removeObject(forKey: wifiOnlyKey)
        UserDefaults.standard.removeObject(forKey: bandwidthKey)
        UserDefaults.standard.removeObject(forKey: lowBatteryPauseKey)
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

    // MARK: - PowerNetworkMonitor (Low Battery Auto-Pause)

    /// The absent-key default (true) must match the Settings UI's @AppStorage
    /// default, so a fresh install behaves exactly the way the toggle shows.
    @MainActor
    func testLowBatteryAutoPauseDefaultsToEnabledWhenKeyAbsent() {
        let monitor = PowerNetworkMonitor()
        UserDefaults.standard.removeObject(forKey: lowBatteryPauseKey)

        XCTAssertTrue(monitor.lowBatteryAutoPauseEnabled(),
                      "Absent key must default to ON, matching the Settings UI default.")
    }

    /// Toggling Low Battery Auto-Pause is read live from UserDefaults on
    /// every re-evaluation — no restart required.
    @MainActor
    func testLowBatteryAutoPauseResyncsFromSettings() {
        let monitor = PowerNetworkMonitor()

        UserDefaults.standard.set(false, forKey: lowBatteryPauseKey)
        monitor.handleUserDefaultsChange()
        XCTAssertFalse(monitor.lowBatteryAutoPauseEnabled(),
                       "Settings change to Low Battery Auto-Pause must reach the live monitor")

        UserDefaults.standard.set(true, forKey: lowBatteryPauseKey)
        monitor.handleUserDefaultsChange()
        XCTAssertTrue(monitor.lowBatteryAutoPauseEnabled(),
                      "Re-enabling must be read back immediately")
    }
}
