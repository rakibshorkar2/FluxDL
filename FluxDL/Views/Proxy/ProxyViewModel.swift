import Foundation
import Combine

@MainActor
public final class ProxyViewModel: ObservableObject {
    public let service: ProxyService

    // MARK: Sheet presentation

    @Published public var isAddSheetPresented = false
    @Published public var isYAMLImportPresented = false
    @Published public var yamlImportResult: ProxyYAMLImportResult?
    @Published public var isYAMLResultsPresented = false
    @Published public var editingProfile: ProxyProfile?
    @Published public var profileForTest: ProxyProfile?

    // MARK: Alerts

    @Published public var alertMessage: String?
    @Published public var isAlertPresented = false
    @Published public var profilePendingDelete: ProxyProfile?
    @Published public var isDeleteConfirmationPresented = false

    public init(service: ProxyService? = nil) {
        self.service = service ?? ((ServiceContainer.shared.proxyService as? ProxyService) ?? ProxyService())
    }

    // MARK: - Profile actions

    public func selectProfile(_ profile: ProxyProfile) {
        guard profile.id != service.selectedProfileID else { return }
        service.selectProfile(id: profile.id)
        service.hapticService.selectionChanged()
    }

    public func confirmDelete(_ profile: ProxyProfile) {
        profilePendingDelete = profile
        isDeleteConfirmationPresented = true
    }

    public func deleteProfile(_ profile: ProxyProfile) {
        service.deleteProfile(id: profile.id)
        service.hapticService.notificationOccurred(.warning)
    }

    public func testProfile(_ profile: ProxyProfile) {
        profileForTest = profile
        Task {
            // Goes through the service so the Keychain password is restored —
            // a test on a saved profile must reflect its stored credentials.
            let result = await service.testProfile(profile)
            presentTestResult(result)
            profileForTest = nil
        }
    }

    public func testConfiguration(_ configuration: ProxyConfiguration, completion: @escaping (ProxyTestResult) -> Void) {
        Task {
            let result = await runTest(configuration)
            if let result = result {
                completion(result)
            }
        }
    }

    private func runTest(_ configuration: ProxyConfiguration) async -> ProxyTestResult? {
        do {
            return try await service.test(configuration)
        } catch {
            return ProxyTestResult.failure(.generalFailure)
        }
    }

    private func presentTestResult(_ result: ProxyTestResult) {
        if result.success, let latencyMs = result.latencyMs {
            alertMessage = "Connected \u{2022} \(latencyMs) ms"
            service.hapticService.notificationOccurred(.success)
        } else {
            alertMessage = result.failure?.userMessage ?? "Connection failed"
            service.hapticService.notificationOccurred(.error)
        }
        isAlertPresented = true
    }

    // MARK: - Enable / Disable

    public func toggleEnabled() {
        if service.isEnabled {
            disable()
        } else {
            enable()
        }
    }

    public func enable() {
        Task {
            await service.enable()
            service.hapticService.impactOccurred(.light)
            if service.connectionState == .failed {
                service.hapticService.notificationOccurred(.error)
            }
        }
    }

    public func disable() {
        service.disable()
        service.hapticService.impactOccurred(.light)
    }

    // MARK: - YAML import

    public func importYAML(_ text: String) {
        guard let result = service.parseYAML(text) else {
            alertMessage = "The selected file could not be parsed as YAML."
            isAlertPresented = true
            return
        }
        yamlImportResult = result
        if result.configurations.isEmpty && result.errors.isEmpty {
            alertMessage = "No proxy configuration found in the selected file."
            isAlertPresented = true
        } else {
            isYAMLResultsPresented = true
        }
    }

    public func importConfigurations(_ configurations: [ProxyConfiguration]) {
        guard !configurations.isEmpty else { return }
        let imported = service.importConfigurations(configurations)
        var message = "Imported \(imported.configurations.count) prox"
        if imported.duplicateCount > 0 {
            message += " (skipped \(imported.duplicateCount) existing)"
        }
        message += "."
        alertMessage = imported.configurations.isEmpty
            ? "All selected proxies already exist."
            : message
        isAlertPresented = true
        service.hapticService.notificationOccurred(.success)
    }

    public func showError(_ message: String) {
        alertMessage = message
        isAlertPresented = true
    }
}
