import XCTest
@testable import FluxDL

@MainActor
final class SettingsServiceTests: XCTestCase {
    var sut: SettingsService!
    
    override func setUp() {
        super.setUp()
        sut = SettingsService()
    }
    
    override func tearDown() {
        sut = nil
        super.tearDown()
    }
    
    func testAppMetadataValues() {
        XCTAssertEqual(sut.appName, "FluxDL")
        XCTAssertEqual(sut.developerName, "RAKIB")
        XCTAssertEqual(sut.versionString, "1.0.0")
        XCTAssertEqual(sut.buildString, "1")
        XCTAssertNotNil(sut.githubURL)
    }
    
    func testCheckForUpdatesReturnsValidMessage() async {
        let result = await sut.checkForUpdates()
        XCTAssertTrue(result.contains("v1.0.0"))
    }
}
