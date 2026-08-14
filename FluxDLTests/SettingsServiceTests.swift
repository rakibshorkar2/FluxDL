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
    
    // MARK: - Global haptic preference (Settings → Haptic Feedback)
    
    /// Unset preference defaults to enabled — the app's existing default is preserved.
    func testHapticPreferenceDefaultsToEnabled() {
        UserDefaults.standard.removeObject(forKey: HapticService.hapticsEnabledKey)
        let service = HapticService()
        XCTAssertTrue(service.isEnabled)
        // All emission APIs must run cleanly while enabled.
        service.selectionChanged()
        service.impactOccurred(.light)
        service.notificationOccurred(.success)
    }
    
    /// OFF suppresses every FluxDL emission type (no-ops, no crash).
    func testHapticPreferenceDisabledSuppressesAllFeedback() {
        UserDefaults.standard.set(false, forKey: HapticService.hapticsEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: HapticService.hapticsEnabledKey) }
        let service = HapticService()
        XCTAssertFalse(service.isEnabled)
        service.selectionChanged()
        service.impactOccurred(.light)
        service.impactOccurred(.medium)
        service.impactOccurred(.heavy)
        service.notificationOccurred(.success)
        service.notificationOccurred(.warning)
        service.notificationOccurred(.error)
    }
    
    /// ON keeps existing haptic behavior intact.
    func testHapticPreferenceEnabledAllowsFeedback() {
        UserDefaults.standard.set(true, forKey: HapticService.hapticsEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: HapticService.hapticsEnabledKey) }
        let service = HapticService()
        XCTAssertTrue(service.isEnabled)
        service.selectionChanged()
        service.impactOccurred(.soft)
        service.notificationOccurred(.warning)
    }
    
    /// A preference change takes effect immediately: an existing service
    /// instance (no recreation, no restart) must stop emitting as soon as the
    /// key flips to OFF, because the gate reads the current value at emission.
    func testHapticPreferenceChangeTakesEffectImmediately() {
        UserDefaults.standard.set(true, forKey: HapticService.hapticsEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: HapticService.hapticsEnabledKey) }
        let service = HapticService()
        XCTAssertTrue(service.isEnabled)
        
        UserDefaults.standard.set(false, forKey: HapticService.hapticsEnabledKey)
        XCTAssertFalse(service.isEnabled, "OFF must apply immediately, without recreation or restart")
        service.selectionChanged()
        service.impactOccurred(.light)
        service.notificationOccurred(.success)
    }
    
    /// The preference persists across app relaunch (simulated with a fresh
    /// service instance reading the stored key).
    func testHapticPreferencePersistsAcrossRelaunch() {
        UserDefaults.standard.set(false, forKey: HapticService.hapticsEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: HapticService.hapticsEnabledKey) }
        XCTAssertFalse(HapticService().isEnabled, "OFF must survive relaunch")
        
        UserDefaults.standard.set(true, forKey: HapticService.hapticsEnabledKey)
        XCTAssertTrue(HapticService().isEnabled, "ON must survive relaunch")
    }
}
