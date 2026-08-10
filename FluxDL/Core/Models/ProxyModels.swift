import Foundation

// MARK: - ProxyType
//
// Supported proxy protocols: HTTP, HTTPS (TLS to proxy + CONNECT), SOCKS4/4a
// and SOCKS5. Each protocol is handled by a dedicated transport inside the
// proxy subsystem; no consumer of these models ever sees protocol details.

public enum ProxyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case http = "http"
    case https = "https"
    case socks4 = "socks4"
    case socks5 = "socks5"

    public var id: String { rawValue }

    /// Display name shown in the UI.
    public var displayName: String {
        switch self {
        case .http:   return "HTTP"
        case .https:  return "HTTPS"
        case .socks4: return "SOCKS4"
        case .socks5: return "SOCKS5"
        }
    }

    /// SF Symbol used for the type.
    public var systemImage: String {
        switch self {
        case .http:   return "globe"
        case .https:  return "lock.shield"
        case .socks4: return "network"
        case .socks5: return "network"
        }
    }

    /// Whether the protocol supports username/password authentication.
    /// SOCKS4/4a have no challenge mechanism (only an optional USERID).
    public var supportsUsernamePasswordAuth: Bool {
        switch self {
        case .http, .https, .socks5: return true
        case .socks4: return false
        }
    }

    /// Whether the destination hostname is handed to the proxy (remote DNS).
    /// SOCKS5 domain addresses (RFC 1928) and SOCKS4a use remote resolution.
    public var supportsRemoteDns: Bool {
        switch self {
        case .socks5: return true
        case .socks4: return true // via SOCKS4a hostname form
        case .http, .https: return false
        }
    }
}

// MARK: - ProxyConnectionState

public enum ProxyConnectionState: String, Codable, Sendable {
    case disabled
    case connecting
    case connected
    case failed

    public var userMessage: String {
        switch self {
        case .disabled:   return "Proxy Disabled"
        case .connecting: return "Testing..."
        case .connected:  return "Proxy Enabled"
        case .failed:     return "Connection Failed"
        }
    }
}

// MARK: - ProxyTestFailure
//
// Every failure carries a concrete, user-presentable reason. Passwords are
// NEVER included in any message — masked values only.

public enum ProxyTestFailure: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case timedOut
    case connectionRefused
    case connectionFailed
    case networkUnreachable
    case hostUnreachable
    case networkUnavailable
    case dnsFailure
    case authenticationFailed
    case socksAuthenticationFailed
    case httpAuthenticationFailed
    case protocolError
    case socksHandshakeFailed
    case tlsHandshakeFailed
    case destinationConnectionFailed
    case proxyUnavailable
    case generalFailure

    /// Human-readable, credential-free description suitable for the UI.
    public var userMessage: String {
        switch self {
        case .invalidConfiguration(let detail):
            return detail
        case .timedOut:
            return "Connection timed out"
        case .connectionRefused:
            return "Proxy refused connection"
        case .connectionFailed:
            return "Could not connect to proxy"
        case .networkUnreachable:
            return "Network unreachable"
        case .hostUnreachable:
            return "Proxy host unreachable"
        case .networkUnavailable:
            return "Network unavailable"
        case .dnsFailure:
            return "DNS resolution failed"
        case .authenticationFailed:
            return "SOCKS5 authentication failed"
        case .socksAuthenticationFailed:
            return "SOCKS authentication failed"
        case .httpAuthenticationFailed:
            return "HTTP proxy authentication failed"
        case .protocolError:
            return "Proxy protocol error"
        case .socksHandshakeFailed:
            return "SOCKS handshake failed"
        case .tlsHandshakeFailed:
            return "HTTPS proxy TLS handshake failed"
        case .destinationConnectionFailed:
            return "Destination connection failed"
        case .proxyUnavailable:
            return "Proxy unavailable"
        case .generalFailure:
            return "Connection failed"
        }
    }
}

// MARK: - ProxyTestHistoryEntry
//
// One lightweight record of a past test. Persisted per profile with a bounded
// history length so it never grows without limit.

public struct ProxyTestHistoryEntry: Codable, Equatable, Sendable {
    public let testedAt: Date
    public let latencyMs: Int?
    public let success: Bool
    public let exitIP: String?
    public let failureMessage: String?

    public init(
        testedAt: Date = Date(),
        latencyMs: Int?,
        success: Bool,
        exitIP: String? = nil,
        failureMessage: String? = nil
    ) {
        self.testedAt = testedAt
        self.latencyMs = latencyMs
        self.success = success
        self.exitIP = exitIP
        self.failureMessage = failureMessage
    }
}

// MARK: - ProxyTestResult
//
// Full outcome of a proxy test with per-phase timing:
//   * tcpMs        — raw TCP connection to the proxy
//   * handshakeMs  — negotiated protocol (SOCKS4/4a/5, HTTP/HTTPS CONNECT)
//   * requestMs    — end-to-end HTTP request through the tunnel (≈ latencyMs)
//   * exitIP       — the public IP the destination observed (when resolvable)

public struct ProxyTestResult: Equatable, Sendable {
    public let success: Bool
    /// End-to-end round-trip latency in milliseconds (nil when failed).
    public let latencyMs: Int?
    public let tcpMs: Int?
    public let handshakeMs: Int?
    public let requestMs: Int?
    public let exitIP: String?
    public let failure: ProxyTestFailure?
    public let testedAt: Date

    public init(
        success: Bool,
        latencyMs: Int?,
        failure: ProxyTestFailure?,
        tcpMs: Int? = nil,
        handshakeMs: Int? = nil,
        requestMs: Int? = nil,
        exitIP: String? = nil,
        testedAt: Date = Date()
    ) {
        self.success = success
        self.latencyMs = latencyMs
        self.tcpMs = tcpMs
        self.handshakeMs = handshakeMs
        self.requestMs = requestMs
        self.exitIP = exitIP
        self.failure = failure
        self.testedAt = testedAt
    }

    public static func success(
        latencyMs: Int,
        tcpMs: Int? = nil,
        handshakeMs: Int? = nil,
        requestMs: Int? = nil,
        exitIP: String? = nil
    ) -> ProxyTestResult {
        ProxyTestResult(
            success: true,
            latencyMs: latencyMs,
            failure: nil,
            tcpMs: tcpMs,
            handshakeMs: handshakeMs,
            requestMs: requestMs,
            exitIP: exitIP
        )
    }

    public static func failure(_ failure: ProxyTestFailure) -> ProxyTestResult {
        ProxyTestResult(success: false, latencyMs: nil, failure: failure)
    }

    public static func failure(_ failure: ProxyTestFailure, tcpMs: Int? = nil, handshakeMs: Int? = nil) -> ProxyTestResult {
        ProxyTestResult(
            success: false,
            latencyMs: nil,
            failure: failure,
            tcpMs: tcpMs,
            handshakeMs: handshakeMs
        )
    }
}

// MARK: - ProxyConfiguration
//
// A single proxy endpoint configuration.
//
// IMPORTANT (Security): `password` is NEVER persisted through `Codable`.
// It lives only in memory while the configuration is being edited or tested;
// persisted credentials are stored in the Keychain via `ProxyKeychainStore`.

public struct ProxyConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var type: ProxyType
    public var host: String
    public var port: Int
    public var authenticationEnabled: Bool
    public var username: String
    public var password: String?

    public init(
        id: UUID = UUID(),
        name: String,
        type: ProxyType = .socks5,
        host: String,
        port: Int,
        authenticationEnabled: Bool = false,
        username: String = "",
        password: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.authenticationEnabled = authenticationEnabled
        self.username = username
        self.password = password
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, host, port, authenticationEnabled, username
    }

    /// True when the configuration should authenticate with username/password.
    public var requiresAuthentication: Bool {
        authenticationEnabled && !username.isEmpty
    }

    /// Host with IPv6 literals wrapped in brackets.
    public var displayHost: String {
        ProxyConfigurationValidator.bracketedHost(host)
    }

    /// "host:port" suitable for display (IPv6 literals are bracketed).
    public var hostAndPortString: String {
        "\(displayHost):\(port)"
    }

    /// Stable duplicate fingerprint: type + host + port + username.
    /// Passwords intentionally excluded so re-importing the same proxy with a
    /// different password does not create a duplicate profile.
    public var fingerprint: String {
        let normalizedHost = ProxyConfigurationValidator.normalizedHost(host).lowercased()
        return "\(type.rawValue)|\(normalizedHost)|\(port)|\(username)"
    }
}

// MARK: - ProxyProfile
//
// A saved proxy profile including the last connectivity test outcome, exit IP
// and a bounded test history. Only the password is stored outside this model
// (Keychain).

public struct ProxyProfile: Identifiable, Codable, Equatable, Sendable {
    public var configuration: ProxyConfiguration
    public var lastTestedAt: Date?
    public var lastLatencyMs: Int?
    public var lastConnectionState: ProxyConnectionState?
    public var lastExitIP: String?
    /// Maximum number of history entries kept per profile.
    public static let historyLimit = 5
    public var testHistory: [ProxyTestHistoryEntry]
    public var createdAt: Date
    public var country: String?
    public var notes: String?

    public init(
        configuration: ProxyConfiguration,
        lastTestedAt: Date? = nil,
        lastLatencyMs: Int? = nil,
        lastConnectionState: ProxyConnectionState? = nil,
        lastExitIP: String? = nil,
        testHistory: [ProxyTestHistoryEntry] = [],
        createdAt: Date = Date(),
        country: String? = nil,
        notes: String? = nil
    ) {
        self.configuration = configuration
        self.lastTestedAt = lastTestedAt
        self.lastLatencyMs = lastLatencyMs
        self.lastConnectionState = lastConnectionState
        self.lastExitIP = lastExitIP
        self.testHistory = testHistory
        self.createdAt = createdAt
        self.country = country
        self.notes = notes
    }

    public var id: UUID { configuration.id }

    public var hasLastTest: Bool { lastTestedAt != nil }

    public var isLastTestConnected: Bool {
        lastConnectionState == .connected && lastLatencyMs != nil
    }

    public var fingerprint: String { configuration.fingerprint }

    /// Appends a test outcome to the history, keeping the newest entries only.
    public mutating func recordTest(_ result: ProxyTestResult) {
        testHistory.insert(
            ProxyTestHistoryEntry(
                testedAt: result.testedAt,
                latencyMs: result.latencyMs,
                success: result.success,
                exitIP: result.exitIP,
                failureMessage: result.failure?.userMessage
            ),
            at: 0
        )
        if testHistory.count > Self.historyLimit {
            testHistory.removeLast(testHistory.count - Self.historyLimit)
        }
    }

    // MARK: Codable (backward compatible with pre-existing persisted archives)

    private enum CodingKeys: String, CodingKey {
        case configuration, lastTestedAt, lastLatencyMs, lastConnectionState,
             lastExitIP, testHistory, createdAt, country, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decode(ProxyConfiguration.self, forKey: .configuration)
        lastTestedAt = try container.decodeIfPresent(Date.self, forKey: .lastTestedAt)
        lastLatencyMs = try container.decodeIfPresent(Int.self, forKey: .lastLatencyMs)
        lastConnectionState = try container.decodeIfPresent(ProxyConnectionState.self, forKey: .lastConnectionState)
        lastExitIP = try container.decodeIfPresent(String.self, forKey: .lastExitIP)
        testHistory = try container.decodeIfPresent([ProxyTestHistoryEntry].self, forKey: .testHistory) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        country = try container.decodeIfPresent(String.self, forKey: .country)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configuration, forKey: .configuration)
        try container.encodeIfPresent(lastTestedAt, forKey: .lastTestedAt)
        try container.encodeIfPresent(lastLatencyMs, forKey: .lastLatencyMs)
        try container.encodeIfPresent(lastConnectionState, forKey: .lastConnectionState)
        try container.encodeIfPresent(lastExitIP, forKey: .lastExitIP)
        try container.encode(testHistory, forKey: .testHistory)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

// MARK: - ProxyConfigurationValidator

public enum ProxyConfigurationValidator {

    /// Validates a full configuration. Returns `nil` when valid, otherwise a message.
    public static func validate(_ configuration: ProxyConfiguration) -> String? {
        if let hostIssue = validateHost(configuration.host) { return hostIssue }
        if let portIssue = validatePort(configuration.port) { return portIssue }
        if configuration.authenticationEnabled {
            if configuration.type == .socks4 {
                // SOCKS4 USERID is optional and carries no password — accept
                // a username-only entry; a password is meaningless here.
            } else {
                if configuration.username.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "Username is required when authentication is enabled"
                }
                if configuration.password?.isEmpty != false {
                    return "Password is required when authentication is enabled"
                }
            }
        }
        return nil
    }

    /// Validates a host string. Returns `nil` when valid, otherwise a message.
    public static func validateHost(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Host is required"
        }
        let normalized = normalizedHost(trimmed)
        if normalized.isEmpty {
            return "Invalid host name or IP address"
        }
        if isIPv4(normalized) || isIPv6(normalized) {
            return nil
        }
        if !isValidHostname(normalized) {
            return "Invalid host name or IP address"
        }
        return nil
    }

    /// Validates a port number. Returns `nil` when valid, otherwise a message.
    public static func validatePort(_ port: Int) -> String? {
        guard (1...65535).contains(port) else {
            return "Port must be between 1 and 65535"
        }
        return nil
    }

    // MARK: IPv4 / IPv6 helpers

    public static func isIPv4(_ string: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, string, &address) == 1
    }

    public static func isIPv6(_ string: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, string, &address) == 1
    }

    /// True when a host string is a bracketed IPv6 literal like `[2001:db8::1]`.
    public static func isBracketedIPv6(_ host: String) -> Bool {
        host.hasPrefix("[") && host.hasSuffix("]") && isIPv6(String(host.dropFirst().dropLast()))
    }

    /// Strips surrounding brackets from a bracketed IPv6 literal.
    public static func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// Wraps an unbracketed IPv6 literal in brackets for display / URI use.
    public static func bracketedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if isBracketedIPv6(trimmed) { return trimmed }
        if isIPv6(trimmed) { return "[\(trimmed)]" }
        return trimmed
    }

    /// RFC-1123 style hostname (letters, digits, hyphens, underscores; dot separated labels).
    public static func isValidHostname(_ hostname: String) -> Bool {
        guard !hostname.isEmpty, hostname.count <= 253 else { return false }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        for label in labels {
            guard label.count <= 63 else { return false }
            let characters = label.unicodeScalars
            guard let first = characters.first, let last = characters.last,
                  isHostnameLabelCharacter(first), isHostnameLabelCharacter(last) else { return false }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            let middle = characters.dropFirst().dropLast()
            guard middle.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return true
    }

    private static func isHostnameLabelCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
    }
}

// MARK: - ProxyURIParser
//
// Parses URI-style proxy entries:
//   socks5://user:pass@host:port      socks5h://user:pass@host:port
//   socks4://user@host:port           socks4a://host:port
//   http://user:pass@host:port        https://user:pass@host:port
// IPv6 hosts must use URI brackets: socks5://user:pass@[2001:db8::1]:1080

public enum ProxyURIParser {

    /// Parses a single proxy URI into a configuration. Returns nil when the
    /// value is not a supported, valid proxy URI.
    public static func parse(_ uri: String) -> ProxyConfiguration? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        let type: ProxyType
        switch scheme {
        case "socks5", "socks5h": type = .socks5
        case "socks4", "socks4a": type = .socks4
        case "http":              type = .http
        case "https":             type = .https
        default: return nil
        }

        guard let host = url.host, !host.isEmpty else { return nil }
        let normalizedHost = ProxyConfigurationValidator.normalizedHost(host)
        guard ProxyConfigurationValidator.validateHost(normalizedHost) == nil else { return nil }

        let port: Int
        if let explicitPort = url.port {
            port = explicitPort
        } else {
            port = type == .http || type == .https ? 8080 : 1080
        }
        guard ProxyConfigurationValidator.validatePort(port) == nil else { return nil }

        let username = url.user?.removingPercentEncoding ?? ""
        let password = url.password?.removingPercentEncoding
        let hasCredentials = !username.isEmpty

        let authenticationEnabled: Bool
        if type == .socks4 {
            // SOCKS4: optional USERID only; no password.
            authenticationEnabled = false
        } else {
            authenticationEnabled = hasCredentials
        }

        return ProxyConfiguration(
            name: "\(type.displayName) \(normalizedHost):\(port)",
            type: type,
            host: normalizedHost,
            port: port,
            authenticationEnabled: authenticationEnabled,
            username: username,
            password: password
        )
    }

    /// Parses a list of URIs (one per line or whitespace separated), returning
    /// the valid ones.
    public static func parseList(_ input: String) -> [ProxyConfiguration] {
        let candidates = input
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [ProxyConfiguration] = []
        for candidate in candidates {
            guard let configuration = parse(candidate) else { continue }
            if seen.insert(configuration.fingerprint).inserted {
                result.append(configuration)
            }
        }
        return result
    }
}

// MARK: - Sort & filter preferences

public enum ProxySortOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case type = "Type"
    case latency = "Latency"
    case status = "Status"
    case lastTested = "Last Tested"
    case recentlyAdded = "Recently Added"

    public var id: String { rawValue }

    public func sort(_ profiles: [ProxyProfile]) -> [ProxyProfile] {
        switch self {
        case .name:
            return profiles.sorted { $0.configuration.name.localizedCaseInsensitiveCompare($1.configuration.name) == .orderedAscending }
        case .type:
            return profiles.sorted {
                if $0.configuration.type == $1.configuration.type {
                    return $0.configuration.name.localizedCaseInsensitiveCompare($1.configuration.name) == .orderedAscending
                }
                return $0.configuration.type.rawValue < $1.configuration.type.rawValue
            }
        case .latency:
            return profiles.sorted {
                let a = workingLatency($0), b = workingLatency($1)
                if a == b { return $0.configuration.name < $1.configuration.name }
                return a < b
            }
        case .status:
            return profiles.sorted {
                let a = statusRank($0), b = statusRank($1)
                if a == b { return $0.configuration.name < $1.configuration.name }
                return a < b
            }
        case .lastTested:
            return profiles.sorted {
                let a = $0.lastTestedAt ?? .distantPast, b = $1.lastTestedAt ?? .distantPast
                if a == b { return $0.configuration.name < $1.configuration.name }
                return a > b
            }
        case .recentlyAdded:
            return profiles.sorted {
                let a = $0.createdAt, b = $1.createdAt
                if a == b { return $0.configuration.name < $1.configuration.name }
                return a > b
            }
        }
    }

    /// "Working First": connected proxies before untested, failed last.
    public func sortWorkingFirst(_ profiles: [ProxyProfile]) -> [ProxyProfile] {
        profiles.sorted {
            let a = workingRank($0), b = workingRank($1)
            if a == b { return $0.configuration.name < $1.configuration.name }
            return a < b
        }
    }

    /// "Fastest First": by last recorded latency, untested/failed last.
    public func sortFastestFirst(_ profiles: [ProxyProfile]) -> [ProxyProfile] {
        profiles.sorted {
            let a = workingLatency($0), b = workingLatency($1)
            if a == b { return $0.configuration.name < $1.configuration.name }
            return a < b
        }
    }

    private func workingLatency(_ profile: ProxyProfile) -> Int {
        profile.isLastTestConnected ? (profile.lastLatencyMs ?? .max) : .max
    }

    private func statusRank(_ profile: ProxyProfile) -> Int {
        if profile.isLastTestConnected { return 0 }
        if profile.lastConnectionState == .failed { return 2 }
        return 1
    }

    private func workingRank(_ profile: ProxyProfile) -> Int {
        if profile.isLastTestConnected { return 0 }
        if profile.lastConnectionState == .failed { return 2 }
        return 1
    }
}

public enum ProxyFilterOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case working = "Working"
    case failed = "Failed"
    case untested = "Untested"
    case socks5 = "SOCKS5"
    case socks4 = "SOCKS4"
    case http = "HTTP"
    case https = "HTTPS"

    public var id: String { rawValue }

    public func applies(to profile: ProxyProfile) -> Bool {
        switch self {
        case .all: return true
        case .working: return profile.isLastTestConnected
        case .failed: return profile.lastConnectionState == .failed
        case .untested: return !profile.hasLastTest
        case .socks5: return profile.configuration.type == .socks5
        case .socks4: return profile.configuration.type == .socks4
        case .http: return profile.configuration.type == .http
        case .https: return profile.configuration.type == .https
        }
    }
}

// MARK: - YAML import result

public struct ProxyYAMLImportError: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String?
    public let message: String

    public init(id: UUID = UUID(), displayName: String?, message: String) {
        self.id = id
        self.displayName = displayName
        self.message = message
    }
}

public struct ProxyYAMLImportResult: Equatable, Sendable {
    public var configurations: [ProxyConfiguration]
    public var errors: [ProxyYAMLImportError]
    /// Configurations dropped because an identical profile already exists
    /// (fingerprint match). Reported so batch imports stay transparent.
    public var duplicateCount: Int

    public init(configurations: [ProxyConfiguration] = [], errors: [ProxyYAMLImportError] = [], duplicateCount: Int = 0) {
        self.configurations = configurations
        self.errors = errors
        self.duplicateCount = duplicateCount
    }

    public var validCount: Int { configurations.count }
    public var errorCount: Int { errors.count }
}