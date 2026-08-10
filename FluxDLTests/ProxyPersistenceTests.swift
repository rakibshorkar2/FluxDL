import XCTest
@testable import FluxDL

@MainActor
final class ProxyPersistenceTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var keychain: MockKeychainStore!

    override func setUp() {
        super.setUp()
        suiteName = "ProxyPersistenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        keychain = MockKeychainStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        super.tearDown()
    }

    private func makeService() -> ProxyService {
        ProxyService(keychainStore: keychain, defaults: defaults)
    }

    private func sampleConfiguration() -> ProxyConfiguration {
        ProxyConfiguration(
            name: "Persisted",
            type: .socks5,
            host: "proxy.example.com",
            port: 1080,
            authenticationEnabled: true,
            username: "user",
            password: "secret"
        )
    }

    // MARK: - Profile persistence

    func testProfilesSurviveServiceRecreation() {
        let first = makeService()
        first.addProfile(sampleConfiguration())

        let second = makeService()
        XCTAssertEqual(second.profiles.count, 1)
        XCTAssertEqual(second.profiles.first?.configuration.name, "Persisted")
        XCTAssertEqual(second.profiles.first?.configuration.host, "proxy.example.com")
        XCTAssertEqual(second.profiles.first?.configuration.port, 1080)
    }

    func testPasswordIsStoredInKeychainNotDefaults() {
        let service = makeService()
        let profile = service.addProfile(sampleConfiguration())

        XCTAssertEqual(keychain.password(forProfileID: profile.id), "secret")
        let rawData = defaults.data(forKey: "fluxdl_proxy_profiles_v2")
        XCTAssertNotNil(rawData)
        if let rawData {
            XCTAssertFalse(String(data: rawData, encoding: .utf8)!.contains("secret"))
        }
    }

    func testActiveConfigurationResolvesPasswordFromKeychain() async throws {
        let server = try MockSOCKSServer(behavior: .requireAuth(username: "user", password: "secret"))
        defer { server.stop() }

        let service = makeService()
        let profile = service.addProfile(
            ProxyConfiguration(
                name: "Keychain Auth",
                host: "127.0.0.1",
                port: Int(server.port),
                authenticationEnabled: true,
                username: "user",
                password: nil
            )
        )
        keychain.savePassword("secret", forProfileID: profile.id)

        await service.enable()

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.connectionState, .connected,
                       "The handshake must succeed using the Keychain-resolved password.")
        XCTAssertEqual(service.activeConfiguration?.password, "secret")
        XCTAssertEqual(service.password(forProfileID: profile.id), "secret")
    }

    func testSelectionPersistsAcrossInstances() {
        let first = makeService()
        let profile = first.addProfile(sampleConfiguration())
        first.selectProfile(id: profile.id)

        let second = makeService()
        XCTAssertEqual(second.selectedProfileID, profile.id)
        XCTAssertEqual(second.selectedProfile?.configuration.name, "Persisted")
    }

    func testSelectionRemovalPersists() {
        let first = makeService()
        let profile = first.addProfile(sampleConfiguration())
        first.selectProfile(id: nil)

        let second = makeService()
        XCTAssertNil(second.selectedProfileID)
    }

    // MARK: - Enabled state persistence

    private func makeMockServerProfile(port: Int) -> ProxyConfiguration {
        ProxyConfiguration(
            name: "Local Mock",
            host: "127.0.0.1",
            port: port
        )
    }

    func testEnabledStatePersistsAcrossInstances() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let first = makeService()
        first.addProfile(makeMockServerProfile(port: Int(server.port)))
        await first.enable()
        XCTAssertTrue(first.isEnabled)

        let second = makeService()
        XCTAssertTrue(second.isEnabled, "Enabled state must be restored from defaults.")
        XCTAssertNotNil(second.selectedProfile)
        XCTAssertEqual(second.selectedProfile?.configuration.host, "127.0.0.1")
    }

    func testEnabledStateWithMissingProfileIsReset() {
        let defaults = self.defaults!
        let profileID = UUID()
        defaults.set(true, forKey: "fluxdl_proxy_enabled")
        defaults.set(profileID.uuidString, forKey: "fluxdl_proxy_selected_id")

        let service = makeService()
        XCTAssertFalse(service.isEnabled, "Enabled state must reset when the profile no longer exists.")
        XCTAssertEqual(service.connectionState, .disabled)
        XCTAssertNil(service.selectedProfileID)
    }

    // MARK: - Deletion

    func testDeleteProfileRemovesKeychainEntryAndSelection() {
        let service = makeService()
        let profile = service.addProfile(sampleConfiguration())
        XCTAssertEqual(keychain.password(forProfileID: profile.id), "secret")

        service.deleteProfile(id: profile.id)

        XCTAssertTrue(service.profiles.isEmpty)
        XCTAssertNil(service.selectedProfileID)
        XCTAssertNil(keychain.password(forProfileID: profile.id))

        let reloaded = makeService()
        XCTAssertTrue(reloaded.profiles.isEmpty)
    }

    func testDeleteSelectedEnabledProfileDisables() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let service = makeService()
        let profile = service.addProfile(makeMockServerProfile(port: Int(server.port)))
        await service.enable()
        XCTAssertTrue(service.isEnabled)

        service.deleteProfile(id: profile.id)

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.connectionState, .disabled)
    }

    // MARK: - Profile updates

    func testUpdateProfilePersistsChanges() {
        let service = makeService()
        let profile = service.addProfile(sampleConfiguration())

        var updated = profile.configuration
        updated.host = "new.example.com"
        updated.port = 8080
        updated.password = "newsecret"
        service.updateProfile(ProxyProfile(configuration: updated))

        let reloaded = makeService()
        let stored = reloaded.profiles.first
        XCTAssertEqual(stored?.configuration.host, "new.example.com")
        XCTAssertEqual(stored?.configuration.port, 8080)
        XCTAssertEqual(stored?.configuration.name, "Persisted")
        XCTAssertNil(stored?.configuration.password, "Password must never be persisted in defaults.")
        XCTAssertEqual(keychain.password(forProfileID: profile.id), "newsecret")
    }

    func testUpdateProfileWithEmptyPasswordKeepsKeychainValue() {
        let service = makeService()
        let profile = service.addProfile(sampleConfiguration())

        var updated = profile.configuration
        updated.host = "new.example.com"
        updated.password = ""
        service.updateProfile(ProxyProfile(configuration: updated))

        XCTAssertEqual(keychain.password(forProfileID: profile.id), "secret", "Empty password must keep the Keychain value.")
    }

    func testImportProfileAddsProfile() {
        let service = makeService()
        service.addProfile(sampleConfiguration())
        XCTAssertEqual(service.profiles.count, 1)
    }
}
