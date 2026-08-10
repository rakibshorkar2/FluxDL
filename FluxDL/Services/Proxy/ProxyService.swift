import Foundation
import Combine

// MARK: - ProxyProviding
//
// App-wide proxy contract. Other subsystems (Downloads, Browser) can observe
// and control the proxy through this protocol WITHOUT depending on the
// concrete service or any SwiftUI type. This keeps the proxy subsystem
// decoupled from its consumers.
//
// IMPORTANT — Scope:
//   * The proxy is an APPLICATION-LEVEL proxy. It never touches iOS system
//     proxy settings, Wi-Fi/cellular configuration, VPN profiles, or traffic
//     from other apps, and it uses no private APIs.
//   * The Torrent subsystem is COMPLETELY INDEPENDENT: it must never be
//     routed through this proxy.

@MainActor
public protocol ProxyProviding: AnyObject {
    /// Whether the proxy is currently enabled for app networking.
    var isEnabled: Bool { get }
    /// The configuration currently active when `isEnabled` is true.
    var activeConfiguration: ProxyConfiguration? { get }
    /// Current connection state (disabled / connecting / connected / failed).
    var connectionState: ProxyConnectionState { get }

    /// Enables the proxy using the currently selected profile and verifies
    /// connectivity through a real SOCKS5 handshake.
    func enable() async
    /// Disables the proxy immediately and cancels any in-flight test.
    func disable()
    /// Performs a real connectivity test through the given configuration.
    func test(_ configuration: ProxyConfiguration) async throws -> ProxyTestResult
}

// MARK: - ProxyService

@MainActor
public final class ProxyService: ObservableObject, ProxyProviding {

    // MARK: Configuration

    /// Host used as the end-to-end destination when testing proxy connectivity.
    public static let testTargetHost = "www.example.com"
    public static let testTargetPort: UInt16 = 80
    /// Reasonable overall timeout for a connectivity test.
    public static let testTimeout: TimeInterval = 10

    /// Timeout (seconds) used for connectivity tests. Injectable so tests can
    /// run with short timeouts instead of waiting for the default.
    public var testTimeout: TimeInterval = ProxyService.testTimeout

    // MARK: Published State

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var profiles: [ProxyProfile] = []
    @Published public private(set) var selectedProfileID: UUID?
    @Published public private(set) var connectionState: ProxyConnectionState = .disabled
    @Published public private(set) var activeLatencyMs: Int?
    @Published public private(set) var lastFailureMessage: String?
    @Published public private(set) var isTesting: Bool = false

    public var activeConfiguration: ProxyConfiguration? {
        guard isEnabled, let selectedProfileID,
              let profile = profiles.first(where: { $0.id == selectedProfileID }) else {
            return nil
        }
        return resolvingCredentials(profile.configuration)
    }

    public var selectedProfile: ProxyProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first(where: { $0.id == selectedProfileID })
    }

    // MARK: Private

    private let keychainStore: ProxyKeychainStoring
    private let defaults: UserDefaults
    private let haptics: HapticServiceProtocol
    private var activeTestTask: Task<Void, Never>? = nil

    // MARK: Persistence Keys

    private static let enabledKey = "fluxdl_proxy_enabled"
    private static let selectedProfileIDKey = "fluxdl_proxy_selected_profile_id"
    private static let profilesKey = "fluxdl_proxy_profiles"
    private static let connectionStateKey = "fluxdl_proxy_connection_state"
    private static let activeLatencyKey = "fluxdl_proxy_active_latency_ms"
    private static let failureMessageKey = "fluxdl_proxy_failure_message"

    /// The haptic service used for UI feedback tied to proxy events.
    public let hapticService: HapticServiceProtocol

    public init(
        keychainStore: ProxyKeychainStoring = ProxyKeychainStore(),
        defaults: UserDefaults = .standard,
        hapticService: HapticServiceProtocol? = nil
    ) {
        self.keychainStore = keychainStore
        self.defaults = defaults
        self.hapticService = hapticService ?? HapticService()
        loadPersistedState()
    }

    // MARK: - Profile Management

    /// Adds a new profile. The password (if any) is stored in the Keychain;
    /// the persisted profile never contains it.
    @discardableResult
    public func addProfile(_ configuration: ProxyConfiguration) -> ProxyProfile {
        if let password = configuration.password, !password.isEmpty {
            keychainStore.savePassword(password, forProfileID: configuration.id)
        }
        var stored = configuration
        stored.password = nil
        let profile = ProxyProfile(configuration: stored)
        profiles.append(profile)
        selectProfile(id: profile.id)
        persistProfiles()
        return profile
    }

    /// Updates an existing profile. An empty password keeps the Keychain value.
    public func updateProfile(_ configuration: ProxyConfiguration) {
        guard let index = profiles.firstIndex(where: { $0.id == configuration.id }) else { return }
        if let password = configuration.password, !password.isEmpty {
            keychainStore.savePassword(password, forProfileID: configuration.id)
        }
        var stored = configuration
        stored.password = nil
        var profile = profiles[index]
        profile.configuration = stored
        profiles[index] = profile
        persistProfiles()

        if isEnabled, selectedProfileID == configuration.id {
            // Live config changed while enabled — re-verify connectivity.
            Task { await verifyActiveProxy() }
        }
    }

    public func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        keychainStore.deletePassword(forProfileID: id)
        if selectedProfileID == id {
            selectedProfileID = nil
            if isEnabled {
                disable()
            }
        }
        persistProfiles()
        persistSelection()
    }

    public func selectProfile(id: UUID?) {
        selectedProfileID = id
        persistSelection()
    }

    public func password(forProfileID id: UUID) -> String? {
        keychainStore.password(forProfileID: id)
    }

    /// Imports a valid configuration from YAML (password routed to Keychain).
    @discardableResult
    public func importProfile(_ configuration: ProxyConfiguration) -> ProxyProfile {
        addProfile(configuration)
    }

    /// Parses YAML and returns valid configurations plus per-entry errors.
    public func parseYAML(_ yaml: String) throws -> ProxyYAMLImportResult {
        try ProxyYAMLParser.extractProxies(from: yaml)
    }

    // MARK: - Enable / Disable

    public func enable() async {
        guard !isEnabled, let selectedProfileID,
              let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return }

        activeTestTask?.cancel()
        isEnabled = true
        connectionState = .connecting
        activeLatencyMs = nil
        lastFailureMessage = nil
        persistEnabledState()

        let task = Task { @MainActor in
            await self.verifyActiveProxy()
        }
        activeTestTask = task
        await task.value
    }

    public func disable() {
        activeTestTask?.cancel()
        isEnabled = false
        connectionState = .disabled
        activeLatencyMs = nil
        lastFailureMessage = nil
        isTesting = false
        persistEnabledState()
    }

    // MARK: - Testing

    /// Performs a REAL SOCKS5 handshake through the proxy and measures latency.
    /// Never fake: on success the latency is measured, on failure a meaningful
    /// reason is returned.
    public func test(_ configuration: ProxyConfiguration) async throws -> ProxyTestResult {
        let resolved = resolvingCredentials(configuration)
        guard let validationIssue = ProxyConfigurationValidator.validate(resolved) else {
            let result = await runHandshakeTest(resolved)
            applyTestResult(result, toProfileWithID: resolved.id)
            if isEnabled, resolved.id == selectedProfileID {
                connectionState = result.success ? .connected : .failed
                activeLatencyMs = result.latencyMs
                lastFailureMessage = result.failure?.userMessage
            }
            persistTestState()
            return result
        }
        return ProxyTestResult.failure(.invalidConfiguration(validationIssue))
    }

    private func verifyActiveProxy() async {
        isTesting = true
        defer { isTesting = false }
        guard let configuration = activeConfiguration else {
            connectionState = .failed
            lastFailureMessage = "No proxy selected"
            return
        }
        let result = await runHandshakeTest(configuration)
        guard isEnabled else { return }
        connectionState = result.success ? .connected : .failed
        activeLatencyMs = result.latencyMs
        lastFailureMessage = result.success ? nil : result.failure?.userMessage
        persistTestState()
    }

    private func runHandshakeTest(_ configuration: ProxyConfiguration) async -> ProxyTestResult {
        let client = SOCKS5Client(
            configuration: configuration,
            targetHost: Self.testTargetHost,
            targetPort: Self.testTargetPort,
            timeout: testTimeout
        )
        do {
            let elapsed = try await client.performConnectTest()
            let latencyMs = max(1, Int((elapsed * 1000).rounded()))
            return ProxyTestResult.success(latencyMs: latencyMs)
        } catch let failure as ProxyTestFailure {
            return ProxyTestResult.failure(failure)
        } catch is CancellationError {
            return ProxyTestResult.failure(.timedOut)
        } catch {
            return ProxyTestResult.failure(.connectionFailed)
        }
    }

    // MARK: - Credentials

    /// Returns a configuration with the Keychain password filled in when the
    /// configuration belongs to a stored profile.
    private func resolvingCredentials(_ configuration: ProxyConfiguration) -> ProxyConfiguration {
        guard configuration.password == nil || configuration.password?.isEmpty == true else {
            return configuration
        }
        var resolved = configuration
        if let stored = keychainStore.password(forProfileID: configuration.id) {
            resolved.password = stored
        }
        return resolved
    }

    // MARK: - Test result bookkeeping

    private func applyTestResult(_ result: ProxyTestResult, toProfileWithID id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var profile = profiles[index]
        profile.lastTestedAt = result.testedAt
        profile.lastLatencyMs = result.latencyMs
        profile.lastConnectionState = result.success ? .connected : .failed
        profiles[index] = profile
        persistProfiles()
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([ProxyProfile].self, from: data) {
            profiles = decoded
        }

        if let rawID = defaults.string(forKey: Self.selectedProfileIDKey) {
            selectedProfileID = UUID(uuidString: rawID)
        }

        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let rawState = defaults.string(forKey: Self.connectionStateKey),
           let state = ProxyConnectionState(rawValue: rawState) {
            connectionState = state
        } else {
            connectionState = isEnabled ? .connected : .disabled
        }

        let latency = defaults.integer(forKey: Self.activeLatencyKey)
        activeLatencyMs = latency > 0 ? latency : nil
        lastFailureMessage = defaults.string(forKey: Self.failureMessageKey)

        // If the persisted "enabled" profile no longer exists, disable.
        if isEnabled {
            if let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID }) {
                // Restored as-is.
            } else {
                isEnabled = false
                connectionState = .disabled
                persistEnabledState()
            }
        }
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    private func persistSelection() {
        defaults.set(selectedProfileID?.uuidString, forKey: Self.selectedProfileIDKey)
    }

    private func persistEnabledState() {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        persistTestState()
    }

    private func persistTestState() {
        defaults.set(connectionState.rawValue, forKey: Self.connectionStateKey)
        if let latency = activeLatencyMs {
            defaults.set(latency, forKey: Self.activeLatencyKey)
        } else {
            defaults.removeObject(forKey: Self.activeLatencyKey)
        }
        if let message = lastFailureMessage {
            defaults.set(message, forKey: Self.failureMessageKey)
        } else {
            defaults.removeObject(forKey: Self.failureMessageKey)
        }
    }
}
