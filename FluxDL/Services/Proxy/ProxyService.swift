import Foundation
import Combine

// MARK: - ProxyProviding
//
// App-wide proxy contract. Other subsystems (Downloads, Browser) depend on
// this protocol rather than the concrete service, keeping the proxy
// subsystem decoupled from its consumers.
//
// IMPORTANT — Scope:
//   * The proxy is an APPLICATION-LEVEL proxy only. It never touches iOS
//     system proxy settings, Wi-Fi/cellular configuration, VPN profiles or
//     private APIs, and it does not affect traffic from other apps.
//   * The Torrent subsystem is entirely independent and must NEVER be
//     routed through this proxy.
//   * No silent fallback: when the proxy is enabled but fails, app requests
//     fail rather than leaking traffic.

@MainActor
public protocol ProxyProviding: AnyObject {
    var isEnabled: Bool { get }
    var activeConfiguration: ProxyConfiguration? { get }
    var connectionState: ProxyConnectionState { get }
    var browserProxyEnabled: Bool { get }
    var downloadsProxyEnabled: Bool { get }
    func enable() async
    func disable()
    func activate(_ proxy: ProxyProfile) async throws
    func deactivate()
    func test(_ configuration: ProxyConfiguration) async throws -> ProxyTestResult
}

public enum ProxyServiceError: Error {
    case noProfileSelected
    case notEnabled
}

@MainActor
public final class ProxyService: ObservableObject, ProxyProviding {

    // MARK: Public configuration

    /// Overall timeout (seconds) applied to each connectivity probe.
    public var testTimeout: TimeInterval = 10
    /// Maximum retries performed by consumer sessions when failover is
    /// enabled (used by session wrappers; handshakes are single-shot).
    public var failoverMaxRetries: Int = 2

    // MARK: Persistence keys

    private enum Key {
        static let profiles = "fluxdl_proxy_profiles_v2"
        static let selectedProfileID = "fluxdl_proxy_selected_id"
        static let isEnabled = "fluxdl_proxy_enabled"
        static let browserRouting = "fluxdl_proxy_browser_routing"
        static let downloadsRouting = "fluxdl_proxy_downloads_routing"
        static let failoverEnabled = "fluxdl_proxy_failover_enabled"
        static let sortOption = "fluxdl_proxy_sort_option"
        static let filterOption = "fluxdl_proxy_filter_option"
        static let bundledImportDone = "fluxdl_proxy_bundled_import_done"
    }

    // MARK: Dependencies

    private let keychainStore: ProxyKeychainStoring
    public let defaults: UserDefaults
    public let hapticService: HapticServiceProtocol

    // MARK: Published state

    @Published public private(set) var profiles: [ProxyProfile] = []
    @Published public private(set) var selectedProfileID: UUID?
    @Published public private(set) var isEnabled = false
    @Published public private(set) var connectionState: ProxyConnectionState
        = ProxyConnectionState.disabled
    @Published public private(set) var activeConfiguration: ProxyConfiguration?
    @Published public private(set) var isTesting = false
    @Published public private(set) var lastTestResult: ProxyTestResult?
    @Published public private(set) var effectiveness: ProxyEffectivenessChecker.Result?
    @Published public private(set) var bulkTestProgress: (completed: Int, total: Int, succeeded: Int)?
    @Published public private(set) var isBulkTesting = false

    @Published public var browserProxyEnabled = false {
        didSet { defaults.set(browserProxyEnabled, forKey: Key.browserRouting) }
    }
    @Published public var downloadsProxyEnabled = false {
        didSet { defaults.set(downloadsProxyEnabled, forKey: Key.downloadsRouting) }
    }
    @Published public var failoverEnabled = false {
        didSet { defaults.set(failoverEnabled, forKey: Key.failoverEnabled) }
    }
    @Published public var sortOption: ProxySortOption = .name {
        didSet { defaults.set(sortOption.rawValue, forKey: Key.sortOption) }
    }
    @Published public var filterOption: ProxyFilterOption = .all {
        didSet { defaults.set(filterOption.rawValue, forKey: Key.filterOption) }
    }

    // MARK: Runtime state

    private let sessionProvider = ProxySessionProvider()
    private var bulkTask: Task<Void, Never>?
    private var activeEnableTask: Task<ProxyTestResult, Error>?
    /// Optional hook for consumers that must rebuild their networking when
    /// the effective routing state changes (DownloadEngine, Browser).
    public var onProxyStateChange: (() -> Void)?

    // MARK: Init

    public init(
        keychainStore: ProxyKeychainStoring = ProxyKeychainStore(),
        defaults: UserDefaults = .standard,
        hapticService: HapticServiceProtocol = MainActor.assumeIsolated { HapticService() }
    ) {
        self.keychainStore = keychainStore
        self.defaults = defaults
        self.hapticService = hapticService
        loadState()
    }

    // MARK: - State persistence

    private func loadState() {
        if let data = defaults.data(forKey: Key.profiles),
           let decoded = try? JSONDecoder().decode([ProxyProfile].self, from: data) {
            profiles = decoded
        }
        if let idString = defaults.string(forKey: Key.selectedProfileID),
           let id = UUID(uuidString: idString),
           profiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
        // Enabled state is restored so the user's routing choice survives
        // relaunch. Connectivity is always re-verified on the next enable();
        // session consumers re-check `isEnabled` before routing anything.
        isEnabled = defaults.bool(forKey: Key.isEnabled) && selectedProfileID != nil
        if isEnabled {
            connectionState = .connected
            if let selectedProfile {
                activeConfiguration = resolveConfiguration(selectedProfile)
            }
        } else {
            connectionState = .disabled
        }
        browserProxyEnabled = defaults.bool(forKey: Key.browserRouting)
        downloadsProxyEnabled = defaults.bool(forKey: Key.downloadsRouting)
        failoverEnabled = defaults.bool(forKey: Key.failoverEnabled)
        if let raw = defaults.string(forKey: Key.sortOption),
           let option = ProxySortOption(rawValue: raw) {
            sortOption = option
        }
        if let raw = defaults.string(forKey: Key.filterOption),
           let option = ProxyFilterOption(rawValue: raw) {
            filterOption = option
        }
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Key.profiles)
        }
    }

    // MARK: - Profile access

    public var selectedProfile: ProxyProfile? {
        guard let id = selectedProfileID else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    public var activeProfile: ProxyProfile? {
        guard isEnabled else { return nil }
        return selectedProfile
    }

    /// Builds the runtime configuration for a profile, restoring the Keychain
    /// password when authentication is enabled. The password never enters
    /// any persisted representation.
    private func resolveConfiguration(_ profile: ProxyProfile) -> ProxyConfiguration {
        var configuration = profile.configuration
        if configuration.authenticationEnabled {
            configuration.password = keychainStore.password(forProfileID: profile.id)
        }
        return configuration
    }

    // MARK: - Selection / CRUD

    @discardableResult
    public func addProfile(_ configuration: ProxyConfiguration) -> ProxyProfile {
        var profile = ProxyProfile(configuration: configuration)
        if configuration.authenticationEnabled,
           let password = configuration.password {
            keychainStore.savePassword(password, forProfileID: profile.id)
            profile.configuration.password = nil
        }
        profiles.append(profile)
        persistProfiles()
        // First added profile becomes the selection so the main toggle is
        // immediately available.
        if selectedProfileID == nil {
            selectedProfileID = profile.id
            defaults.set(profile.id.uuidString, forKey: Key.selectedProfileID)
        }
        hapticService.notificationOccurred(.success)
        return profile
    }

    /// Updates an existing profile. Runtime tracking fields (test history,
    /// last result) are write-protected — they are only changed by the
    /// test pipeline.
    public func updateProfile(_ profile: ProxyProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.testHistory = profiles[index].testHistory
        updated.lastTestedAt = profiles[index].lastTestedAt
        updated.lastLatencyMs = profiles[index].lastLatencyMs
        updated.lastConnectionState = profiles[index].lastConnectionState
        updated.lastExitIP = profiles[index].lastExitIP
        updated.createdAt = profiles[index].createdAt

        if updated.configuration.authenticationEnabled,
           let password = updated.configuration.password,
           !password.isEmpty {
            keychainStore.savePassword(password, forProfileID: updated.id)
            updated.configuration.password = nil
        } else if !updated.configuration.authenticationEnabled {
            keychainStore.deletePassword(forProfileID: updated.id)
        }
        profiles[index] = updated
        persistProfiles()
        if activeProfile?.id == updated.id {
            activeConfiguration = resolveConfiguration(updated)
        }
    }

    public func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        keychainStore.deletePassword(forProfileID: id)
        if selectedProfileID == id {
            selectedProfileID = nil
            defaults.removeObject(forKey: Key.selectedProfileID)
            if isEnabled {
                disable()
            }
        }
        persistProfiles()
    }

    public func selectProfile(id: UUID?) {
        guard let id else {
            // nil clears the selection (and disables an active proxy).
            selectedProfileID = nil
            defaults.removeObject(forKey: Key.selectedProfileID)
            if isEnabled {
                disable()
            }
            return
        }
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        defaults.set(id.uuidString, forKey: Key.selectedProfileID)
        if isEnabled, let profile = selectedProfile {
            activeConfiguration = resolveConfiguration(profile)
        }
    }

    // MARK: - Enabled profile list (filtering / sorting are preferences)

    /// Profiles after applying the current filter and sort options.
    public func visibleProfiles() -> [ProxyProfile] {
        let filtered = profiles.filter { filterOption.applies(to: $0) }
        return sortOption.sort(filtered)
    }

    public func setSortOption(_ option: ProxySortOption) {
        sortOption = option
    }

    public func setFilterOption(_ option: ProxyFilterOption) {
        filterOption = option
    }

    // MARK: - Enable / disable

    public func toggleEnabled() {
        if isEnabled {
            disable()
        } else {
            Task { await enable() }
        }
    }

    /// Enables the proxy: the selected profile is probed with a REAL
    /// handshake + HTTP request through the tunnel. Only a successful probe
    /// activates the proxy — enabling is never optimistic. A `disable()`
    /// issued mid-probe cancels the probe and leaves the proxy disabled.
    public func enable() async {
        guard let profile = selectedProfile else { return }
        isTesting = true
        connectionState = .connecting

        let task = Task { @MainActor [weak self] in
            guard let self else { return ProxyTestResult.failure(.connectionFailed) }
            let result = await ProxyTester.test(self.resolveConfiguration(profile), timeout: self.testTimeout)
            if Task.isCancelled {
                throw CancellationError()
            }
            return result
        }
        activeEnableTask = task

        let result: ProxyTestResult
        do {
            result = try await task.value
        } catch {
            // Cancelled by disable() — state already reflects .disabled.
            return
        }
        isTesting = false
        applyTestResult(result, to: profile.id)

        isEnabled = result.success
        connectionState = result.success ? .connected : .failed
        activeConfiguration = result.success ? resolveConfiguration(profile) : nil
        defaults.set(result.success, forKey: Key.isEnabled)
        hapticService.notificationOccurred(result.success ? .success : .error)
        onProxyStateChange?()
    }

    /// Disables the proxy immediately and cancels any in-flight bulk test.
    public func disable() {
        bulkTask?.cancel()
        activeEnableTask?.cancel()
        isEnabled = false
        connectionState = .disabled
        activeConfiguration = nil
        isTesting = false
        defaults.set(false, forKey: Key.isEnabled)
        sessionProvider.stopAdapter()
        onProxyStateChange?()
    }

    public func activate(_ proxy: ProxyProfile) async throws {
        selectProfile(id: proxy.id)
        await enable()
        guard isEnabled else { throw ProxyServiceError.notEnabled }
    }

    public func deactivate() {
        disable()
    }

    // MARK: - Testing

    public func test(_ configuration: ProxyConfiguration) async throws -> ProxyTestResult {
        isTesting = true
        defer { isTesting = false }
        let result = await ProxyTester.test(configuration, timeout: testTimeout)
        // A manual test on a saved profile also refreshes its stored outcome.
        if let profile = profiles.first(where: { $0.id == configuration.id }) {
            applyTestResult(result, to: profile.id)
        } else if let profile = profiles.first(where: { $0.fingerprint == configuration.fingerprint }) {
            applyTestResult(result, to: profile.id)
        }
        return result
    }

    /// Tests a saved profile with its Keychain credentials restored and
    /// persists the outcome (latency, state, exit IP, history).
    public func testProfile(_ profile: ProxyProfile) async -> ProxyTestResult {
        isTesting = true
        defer { isTesting = false }
        let result = await ProxyTester.test(resolveConfiguration(profile), timeout: testTimeout)
        applyTestResult(result, to: profile.id)
        return result
    }

    private func applyTestResult(_ result: ProxyTestResult, to id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastTestedAt = result.testedAt
        profiles[index].lastLatencyMs = result.latencyMs
        profiles[index].lastConnectionState = result.success ? .connected : .failed
        profiles[index].lastExitIP = result.exitIP
        profiles[index].recordTest(result)
        persistProfiles()
        lastTestResult = result
    }

    // MARK: - Test All

    /// Probes every profile concurrently (bounded by the tunnel limit) and
    /// persists each outcome as it completes.
    public func testAll() {
        bulkTask?.cancel()
        let items = profiles.map {
            ProxyBulkTester.Item(id: $0.id, configuration: resolveConfiguration($0))
        }
        guard !items.isEmpty else { return }

        isBulkTesting = true
        bulkTestProgress = (0, items.count, 0)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await ProxyBulkTester.testAll(
                items,
                timeout: self.testTimeout,
                progress: { completed, total, succeeded in
                    let progress = (completed, total, succeeded)
                    Task { @MainActor in
                        self.bulkTestProgress = progress
                    }
                }
            )
            guard !Task.isCancelled else {
                self.isBulkTesting = false
                return
            }
            for (id, result) in results {
                self.applyTestResult(result, to: id)
            }
            let succeeded = results.values.filter(\.success).count
            self.bulkTestProgress = (items.count, items.count, succeeded)
            self.isBulkTesting = false
        }
        bulkTask = task
    }

    public func cancelBulkTesting() {
        bulkTask?.cancel()
        isBulkTesting = false
    }

    // MARK: - Effectiveness check

    /// Verifies that a real session built with the proxy configuration used
    /// by the Downloads/Browser layers actually exits through the proxy.
    /// Result is published but never persisted.
    public func checkEffectiveness() async -> ProxyEffectivenessChecker.Result? {
        guard isEnabled, let active = activeConfiguration else { return nil }
        let sessionConfiguration = sessionProvider.sessionConfiguration(for: active)
        let result = await ProxyEffectivenessChecker.check(
            sessionConfiguration: sessionConfiguration,
            timeout: testTimeout
        )
        effectiveness = result
        return result
    }

    // MARK: - YAML / bundled import

    /// Imports the bundled test proxies once (marker survives in UserDefaults).
    /// Deduplicated against existing fingerprints; never auto-enables.
    public func importBundledIfNeeded() -> Bool {
        guard !defaults.bool(forKey: Key.bundledImportDone) else { return false }
        defaults.set(true, forKey: Key.bundledImportDone)
        return importBundled()
    }

    @discardableResult
    public func importBundled() -> Bool {
        guard let url = Bundle.main.url(forResource: "DefaultProxies", withExtension: "yaml"),
              let data = try? Data(contentsOf: url),
              let yaml = String(data: data, encoding: .utf8),
              let result = importYAML(yaml),
              !result.configurations.isEmpty else {
            return false
        }
        return true
    }

    /// Parses a YAML document and imports every valid entry (deduplicated).
    /// Returns nil only when the document itself is unparseable.
    @discardableResult
    public func importYAML(_ yaml: String) -> ProxyYAMLImportResult? {
        guard let parsed = try? ProxyYAMLParser.extractProxies(from: yaml) else {
            return nil
        }
        let imported = importConfigurations(parsed.configurations)
        var merged = parsed
        merged.duplicateCount += imported.duplicateCount
        return merged
    }

    /// Convenience: importYAML over raw Data (UTF-8).
    @discardableResult
    public func importYAML(_ data: Data) -> ProxyYAMLImportResult? {
        guard let yaml = String(data: data, encoding: .utf8) else { return nil }
        return importYAML(yaml)
    }

    /// Parses a YAML document WITHOUT importing anything. Used by the
    /// preview-then-commit import flow so users can review entries before
    /// they become profiles. Returns nil only when the document itself is
    /// unparseable.
    public func parseYAML(_ yaml: String) -> ProxyYAMLImportResult? {
        try? ProxyYAMLParser.extractProxies(from: yaml)
    }

    /// Keychain password for a profile — used by edit flows so an empty
    /// password field means "keep the stored one".
    public func password(forProfileID id: UUID) -> String? {
        keychainStore.password(forProfileID: id)
    }

    /// Imports configurations, skipping fingerprints that already exist so
    /// re-imports never create duplicates.
    @discardableResult
    public func importConfigurations(_ configurations: [ProxyConfiguration]) -> ProxyYAMLImportResult {
        var imported = ProxyYAMLImportResult()
        let existing = Set(profiles.map(\.fingerprint))
        for configuration in configurations {
            guard !existing.contains(configuration.fingerprint) else {
                imported.duplicateCount += 1
                continue
            }
            _ = addProfile(configuration)
            imported.configurations.append(configuration)
        }
        return imported
    }

    deinit {
        bulkTask?.cancel()
        activeEnableTask?.cancel()
    }
}