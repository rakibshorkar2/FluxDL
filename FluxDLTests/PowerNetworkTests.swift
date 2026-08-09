import XCTest
@testable import FluxDL

final class PowerNetworkTests: XCTestCase {
    
    @MainActor
    func testPowerNetworkMonitorDefaults() {
        let monitor = PowerNetworkMonitor()
        XCTAssertFalse(monitor.isWiFiOnlyEnabled)
        XCTAssertEqual(monitor.bandwidthLimitKBps, 0)
    }
    
    func testClipboardServiceDismiss() {
        let service = ClipboardService()
        service.dismissDetectedURL()
        XCTAssertNil(service.detectedURL)
    }
}
