import XCTest
@testable import FluxDL

// MARK: - ProxyUITests
//
// Behavior tests for the Proxy UI layer (view model state driving the
// ProxyView, AddEditProxySheet, and ProxyYAMLImportView). The codebase has
// no UI-rendering test infrastructure, so these cover the state transitions
// the views bind to.

@MainActor
final class ProxyUITests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var keychain: MockKeychainStore!
    private var service: ProxyService!
    private var viewModel: ProxyViewModel!

    override func setUp() {
        super.setUp()
        suiteName = "ProxyUITests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        keychain = MockKeychainStore()
        service = ProxyService(keychainStore: keychain, defaults: defaults)
        service.testTimeout = 2
        viewModel = ProxyViewModel(service: service)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        service = nil
        viewModel = nil
        super.tearDown()
    }

    private func mockProfile(port: Int) -> ProxyProfile {
        service.addProfile(
            ProxyConfiguration(name: "Mock", host: "127.0.0.1", port: port)
        )
    }

    // MARK: - Add sheet presentation

    func testAddSheetPresentationFlow() {
        XCTAssertFalse(viewModel.isAddSheetPresented)

        viewModel.editingProfile = nil
        viewModel.isAddSheetPresented = true
        XCTAssertTrue(viewModel.isAddSheetPresented)

        viewModel.isAddSheetPresented = false
        XCTAssertFalse(viewModel.isAddSheetPresented)
    }

    func testEditSheetUsesSelectedProfile() {
        let profile = mockProfile(port: 1)
        viewModel.editingProfile = profile
        viewModel.isAddSheetPresented = true
        XCTAssertEqual(viewModel.editingProfile?.id, profile.id)
    }

    // MARK: - Profile selection and deletion

    func testSelectProfileOnlySwitchesWhenDifferent() {
        let first = mockProfile(port: 1)
        let second = mockProfile(port: 2)
        XCTAssertEqual(service.selectedProfileID, second.id)

        viewModel.selectProfile(first)
        XCTAssertEqual(service.selectedProfileID, first.id)

        viewModel.selectProfile(first)
        XCTAssertEqual(service.selectedProfileID, first.id, "Selecting the same profile must be a no-op.")
    }

    func testDeleteConfirmationFlow() {
        let profile = mockProfile(port: 1)

        viewModel.confirmDelete(profile)
        XCTAssertTrue(viewModel.isDeleteConfirmationPresented)
        XCTAssertEqual(viewModel.profilePendingDelete?.id, profile.id)

        viewModel.deleteProfile(profile)
        XCTAssertTrue(service.profiles.isEmpty)
        XCTAssertFalse(viewModel.isDeleteConfirmationPresented)
    }

    // MARK: - Enable / disable toggle

    func testToggleEnabledWithNoProfileStaysDisabled() {
        viewModel.toggleEnabled()
        XCTAssertFalse(service.isEnabled)
    }

    func testToggleEnabledWithProfileEnables() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        mockProfile(port: Int(server.port))

        viewModel.toggleEnabled()
        await waitUntilConnected()

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(service.connectionState, .connected)
    }

    func testToggleDisablesAfterEnable() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        mockProfile(port: Int(server.port))
        viewModel.toggleEnabled()
        await waitUntilConnected()

        XCTAssertTrue(service.isEnabled)
        viewModel.toggleEnabled()
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.connectionState, .disabled)
    }

    // MARK: - Test profile

    func testTestProfilePresentsResultAndClearsPendingProfile() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let profile = mockProfile(port: Int(server.port))

        viewModel.testProfile(profile)
        XCTAssertEqual(viewModel.profileForTest?.id, profile.id)

        await waitUntil { viewModel.profileForTest == nil }

        XCTAssertTrue(viewModel.isAlertPresented, "A result alert must be shown after testing.")
        XCTAssertNil(viewModel.profileForTest)
        XCTAssertEqual(service.profiles.first?.lastConnectionState, .connected)
        XCTAssertTrue(viewModel.alertMessage?.contains("ms") == true)
    }

    func testTestConfigurationCompletionHandler() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let configuration = ProxyConfiguration(name: "Direct", host: "127.0.0.1", port: Int(server.port))

        var received: ProxyTestResult?
        viewModel.testConfiguration(configuration) { result in
            received = result
        }

        await waitUntil { received != nil }
        XCTAssertEqual(received?.success, true)
    }

    // MARK: - YAML import

    func testYAMLImportWithValidDocumentPresentsResults() {
        let yaml = """
        proxies:
          - name: From YAML
            type: socks5
            server: example.com
            port: 1080
        """
        viewModel.importYAML(yaml)

        XCTAssertTrue(viewModel.isYAMLResultsPresented)
        XCTAssertEqual(viewModel.yamlImportResult?.validCount, 1)
        XCTAssertFalse(viewModel.isAlertPresented)
    }

    func testYAMLImportWithInvalidDocumentShowsAlert() {
        viewModel.importYAML("this: [is: not: valid")

        XCTAssertFalse(viewModel.isYAMLResultsPresented)
        XCTAssertTrue(viewModel.isAlertPresented)
        XCTAssertNotNil(viewModel.alertMessage)
    }

    func testYAMLImportWithNoProxiesShowsAlert() {
        viewModel.importYAML("just:\n  random: text\n")

        XCTAssertFalse(viewModel.isYAMLResultsPresented)
        XCTAssertTrue(viewModel.isAlertPresented)
        XCTAssertEqual(viewModel.alertMessage, "Invalid YAML: no proxy configuration found in YAML")
    }

    func testImportConfigurationsAddsAllProfiles() {
        let configs = [
            ProxyConfiguration(name: "A", host: "a.example.com", port: 1),
            ProxyConfiguration(name: "B", host: "b.example.com", port: 2)
        ]
        viewModel.importConfigurations(configs)

        XCTAssertEqual(service.profiles.count, 2)
        XCTAssertEqual(Set(service.profiles.map(\.configuration.name)), ["A", "B"])
    }

    func testImportConfigurationsWithEmptyListIsNoOp() {
        viewModel.importConfigurations([])
        XCTAssertTrue(service.profiles.isEmpty)
    }

    // MARK: - Helpers

    private func waitUntilConnected() async {
        await waitUntil { self.service.connectionState == .connected }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
