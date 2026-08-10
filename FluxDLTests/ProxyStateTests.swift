import XCTest
@testable import FluxDL

// MARK: - ProxyStateTests
//
// Exercises the ProxyService state machine end-to-end against a real local
// SOCKS5 server: enable / disable transitions, failure paths, profile
// selection, and live re-verification.

@MainActor
final class ProxyStateTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var keychain: MockKeychainStore!

    override func setUp() {
        super.setUp()
        suiteName = "ProxyStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        keychain = MockKeychainStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        super.tearDown()
    }

    private func makeService(timeout: TimeInterval = 2) -> ProxyService {
        let service = ProxyService(keychainStore: keychain, defaults: defaults)
        service.testTimeout = timeout
        return service
    }

    private func mockProfile(port: Int) -> ProxyProfile {
        ProxyProfile(
            configuration: ProxyConfiguration(
                name: "Mock",
                host: "127.0.0.1",
                port: port
            )
        )
    }

    // MARK: - Enable / disable transitions

    func testEnableWithReachableProxyReachesConnected() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let service = makeService()
        service.addProfile(mockProfile(port: Int(server.port)))

        await service.enable()

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.connectionState, .connected)
        XCTAssertNotNil(service.activeLatencyMs)
        XCTAssertNil(service.lastFailureMessage)
        XCTAssertNotNil(service.activeConfiguration)
        XCTAssertEqual(service.activeConfiguration?.host, "127.0.0.1")
    }

    func testDisableTransitionsToDisabled() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let service = makeService()
        service.addProfile(mockProfile(port: Int(server.port)))
        await service.enable()
        XCTAssertEqual(service.connectionState, .connected)

        service.disable()

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.connectionState, .disabled)
        XCTAssertNil(service.activeLatencyMs)
        XCTAssertNil(service.lastFailureMessage)
        XCTAssertNil(service.activeConfiguration)
    }

    func testEnableWithNoProfileDoesNothing() async {
        let service = makeService()
        await service.enable()
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.connectionState, .disabled)
    }

    func testEnableWithUnreachableProxyReachesFailed() async throws {
        let reserver = try ClosedPortReserver()

        let service = makeService()
        service.addProfile(mockProfile(port: Int(reserver.port)))

        await service.enable()

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.connectionState, .failed)
        XCTAssertNotNil(service.lastFailureMessage)
        XCTAssertNil(service.activeLatencyMs)
    }

    func testEnableAfterDisableReconnects() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let service = makeService()
        service.addProfile(mockProfile(port: Int(server.port)))

        await service.enable()
        XCTAssertEqual(service.connectionState, .connected)

        service.disable()
        XCTAssertEqual(service.connectionState, .disabled)

        await service.enable()
        XCTAssertEqual(service.connectionState, .connected)
    }

    // MARK: - Profile selection

    func testSelectProfileUpdatesSelection() {
        let service = makeService()
        let first = service.addProfile(mockProfile(port: 1))
        let second = service.addProfile(mockProfile(port: 2))

        service.selectProfile(id: first.id)
        XCTAssertEqual(service.selectedProfileID, first.id)

        service.selectProfile(id: second.id)
        XCTAssertEqual(service.selectedProfileID, second.id)
        XCTAssertEqual(service.selectedProfile?.configuration.port, 2)
    }

    func testAddProfileAutoSelects() {
        let service = makeService()
        let profile = service.addProfile(mockProfile(port: 1))
        XCTAssertEqual(service.selectedProfileID, profile.id)
    }

    func testSelectingUnrelatedProfileIDIsAllowedButInactive() {
        let service = makeService()
        service.addProfile(mockProfile(port: 1))
        service.selectProfile(id: UUID())
        XCTAssertNil(service.activeConfiguration)
    }

    // MARK: - Live updates

    func testUpdatingActiveProfileWhileEnabledReVerifies() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let service = makeService()
        let profile = service.addProfile(mockProfile(port: Int(server.port)))
        await service.enable()
        XCTAssertEqual(service.connectionState, .connected)

        var updated = profile.configuration
        updated.name = "Renamed"
        updated.host = "127.0.0.1"
        updated.port = Int(server.port)
        service.updateProfile(updated)

        XCTAssertEqual(service.activeConfiguration?.name, "Renamed")
        XCTAssertTrue(service.isEnabled, "Updating a live profile must keep the proxy enabled.")
    }

    func testUpdatingInactiveProfileDoesNotChangeState() {
        let service = makeService()
        let first = service.addProfile(mockProfile(port: 1))
        let second = service.addProfile(mockProfile(port: 2))
        XCTAssertEqual(service.selectedProfileID, second.id)

        var updated = first.configuration
        updated.host = "other.example.com"
        service.updateProfile(updated)

        XCTAssertEqual(service.selectedProfile?.configuration.host, "127.0.0.1")
        XCTAssertNil(service.activeConfiguration)
    }

    // MARK: - Testing

    func testManualTestUpdatesProfileOutcome() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let service = makeService()
        let profile = service.addProfile(mockProfile(port: Int(server.port)))
        XCTAssertNil(profile.lastTestedAt)

        let result = try await service.test(profile.configuration)

        XCTAssertTrue(result.success)
        let updated = service.profiles.first(where: { $0.id == profile.id })
        XCTAssertEqual(updated?.lastConnectionState, .connected)
        XCTAssertNotNil(updated?.lastLatencyMs)
        XCTAssertNotNil(updated?.lastTestedAt)
    }

    func testManualTestFailureUpdatesProfileOutcome() async throws {
        let reserver = try ClosedPortReserver()

        let service = makeService()
        let profile = service.addProfile(mockProfile(port: Int(reserver.port)))

        let result = try await service.test(profile.configuration)

        XCTAssertFalse(result.success)
        let updated = service.profiles.first(where: { $0.id == profile.id })
        XCTAssertEqual(updated?.lastConnectionState, .failed)
        XCTAssertNil(updated?.lastLatencyMs)
    }

    func testEnableWithAuthenticationFailsOnBadCredentials() async throws {
        let server = try MockSOCKSServer(behavior: .requireAuth(username: "user", password: "pass"))
        defer { server.stop() }

        let service = makeService()
        service.addProfile(
            ProxyConfiguration(
                name: "Auth",
                host: "127.0.0.1",
                port: Int(server.port),
                authenticationEnabled: true,
                username: "user",
                password: "wrong"
            )
        )

        await service.enable()

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.connectionState, .failed)
        XCTAssertEqual(service.lastFailureMessage, ProxyTestFailure.authenticationFailed.userMessage)
    }

    func testDisableCancelsInFlightTest() async throws {
        let server = try MockSOCKSServer(behavior: .silent)
        defer { server.stop() }

        let service = makeService(timeout: 30)
        service.addProfile(mockProfile(port: Int(server.port)))

        let enableTask = Task { await service.enable() }

        try await Task.sleep(nanoseconds: 150_000_000)
        service.disable()
        await enableTask.value

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.connectionState, .disabled)
    }
}
