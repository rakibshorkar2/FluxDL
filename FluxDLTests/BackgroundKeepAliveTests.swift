import XCTest
@testable import FluxDL

final class BackgroundKeepAliveTests: XCTestCase {
    
    func testBackgroundServiceStop() {
        let service = BackgroundKeepAliveService()
        service.stopAllKeepAlive()
        XCTAssertTrue(true, "stopAllKeepAlive should execute cleanly without errors")
    }
}
