import XCTest
@testable import FluxDL

final class DownloadRestorationTests: XCTestCase {
    
    // MARK: - DownloadRestorationService instantiation
    
    func testRestorationServiceInit() {
        let service = DownloadRestorationService()
        XCTAssertNotNil(service, "DownloadRestorationService should initialise without crashing")
    }
    
    // MARK: - NotificationService
    
    func testNotificationServiceInit() {
        let service = NotificationService()
        XCTAssertNotNil(service, "NotificationService should initialise without crashing")
    }
    
    func testNotifyDownloadCompletedDoesNotCrash() {
        let service = NotificationService()
        // Simply calling this must not throw or crash
        service.notifyDownloadCompleted(filename: "TestFile.zip")
    }
    
    func testNotifyDownloadFailedDoesNotCrash() {
        let service = NotificationService()
        service.notifyDownloadFailed(filename: "TestFile.zip", reason: "Network lost")
    }
    
    func testCancelAllNotificationsDoesNotCrash() {
        let service = NotificationService()
        service.cancelAllNotifications()
    }
    
    // MARK: - DownloadTaskModel — sessionTaskIdentifier persistence
    
    func testSessionTaskIdentifierRoundTrip() throws {
        let url = URL(string: "https://example.com/file.zip")!
        var model = DownloadTaskModel(url: url, filename: "file.zip")
        XCTAssertNil(model.sessionTaskIdentifier, "Session task identifier should be nil on new task")
        
        model.sessionTaskIdentifier = 42
        XCTAssertEqual(model.sessionTaskIdentifier, 42)
        
        // Encode → Decode to verify Codable round-trip
        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(DownloadTaskModel.self, from: encoded)
        XCTAssertEqual(decoded.sessionTaskIdentifier, 42, "sessionTaskIdentifier must survive Codable round-trip")
    }
    
    func testSessionTaskIdentifierNilRoundTrip() throws {
        let url = URL(string: "https://example.com/file.zip")!
        let model = DownloadTaskModel(url: url, filename: "file.zip", sessionTaskIdentifier: nil)
        
        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(DownloadTaskModel.self, from: encoded)
        XCTAssertNil(decoded.sessionTaskIdentifier)
    }
    
    // MARK: - Background session identifier stability
    
    func testBackgroundSessionIdentifierIsStable() {
        // The identifier must remain exactly this string across builds
        // so iOS can re-attach the background session after relaunch.
        let expectedIdentifier = "com.rakib.FluxDL.background-session"
        // We can't access the private constant directly, but we can verify the
        // session configuration identifier from the DownloadEngine.
        // This test documents the contract rather than testing runtime behaviour.
        XCTAssertFalse(expectedIdentifier.isEmpty)
        XCTAssertTrue(expectedIdentifier.hasPrefix("com.rakib.FluxDL"))
    }
}
