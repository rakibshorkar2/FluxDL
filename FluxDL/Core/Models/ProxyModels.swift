import Foundation

// MARK: - ProxyType
//
// Supported proxy protocols. New protocols (e.g. HTTP/HTTPS proxy) can be
// added here and handled by dedicated client implementations without touching
// the rest of the proxy subsystem.

public enum ProxyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case socks5 = "socks5"

    public var id: String { rawValue }

    /// Display name shown in the UI.
    public var displayName: String {
        switch self {
        case .socks5: return "SOCKS5"
        }
    }

    /// SF Symbol used for the type.
    public var systemImage: String {
        switch self {
        case .socks5: return "network"
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
        case .disabled:  return "Proxy Disabled"
        case .connecting: return "Testing..."
        case .connected: return "Proxy Enabled"
        case .failed:    return "Connection Failed"
        }
    }
}

// MARK: - ProxyTestFailure

public enum ProxyTestFailure: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case timedOut
    case connectionRefused
    case connectionFailed
    case networkUnreachable
    case hostUnreachable
    case networkUnavailable
    case authenticationFailed
    case protocolError
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
        case .authenticationFailed:
            return "SOCKS5 authentication failed"
        case .protocolError:
            return "SOCKS5 protocol error"
        case .generalFailure:
            return "Connection failed"
        }
    }
}

// MARK: - ProxyTestResult

public struct ProxyTestResult: Equatable, Sendable {
    public let success: Bool
    /// Measured round-trip latency in milliseconds (nil when the test failed).
    public let latencyMs: Int?
    public let failure: ProxyTestFailure?
    public let testedAt: Date

    public init(success: Bool, latencyMs: Int?, failure: ProxyTestFailure?, testedAt: Date = Date()) {
        self.success = success
        self.latencyMs = latencyMs
        self.failure = failure
        self.testedAt = testedAt
    }

    public static func success(latencyMs: Int) -> ProxyTestResult {
        ProxyTestResult(success: true, latencyMs: latencyMs, failure: nil)
    }

    public static func failure(_ failure: ProxyTestFailure) -> ProxyTestResult {
        ProxyTestResult(success: false, latencyMs: nil, failure: failure)
    }
}

// MARK: - ProxyConfiguration

/// A single proxy endpoint configuration.
///
/// IMPORTANT (Security): `password` is NEVER persisted through `Codable`.
/// It lives only in memory while the configuration is being edited or tested;
/// persisted credentials are stored in the Keychain via `ProxyKeychainStore`.
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

    public var hostAndPortString: String {
        "\(host):\(port)"
    }
}

// MARK: - ProxyProfile

/// A saved proxy profile including the last connectivity test outcome.
public struct ProxyProfile: Identifiable, Codable, Equatable, Sendable {
    public var configuration: ProxyConfiguration
    public var lastTestedAt: Date?
    public var lastLatencyMs: Int?
    public var lastConnectionState: ProxyConnectionState?

    public init(
        configuration: ProxyConfiguration,
        lastTestedAt: Date? = nil,
        lastLatencyMs: Int? = nil,
        lastConnectionState: ProxyConnectionState? = nil
    ) {
        self.configuration = configuration
        self.lastTestedAt = lastTestedAt
        self.lastLatencyMs = lastLatencyMs
        self.lastConnectionState = lastConnectionState
    }

    public var id: UUID { configuration.id }

    public var hasLastTest: Bool { lastTestedAt != nil }

    public var isLastTestConnected: Bool {
        lastConnectionState == .connected && lastLatencyMs != nil
    }
}

// MARK: - ProxyConfigurationValidator

public enum ProxyConfigurationValidator {

    /// Validates a full configuration. Returns `nil` when valid, otherwise a message.
    public static func validate(_ configuration: ProxyConfiguration) -> String? {
        if let hostIssue = validateHost(configuration.host) { return hostIssue }
        if let portIssue = validatePort(configuration.port) { return portIssue }
        if configuration.authenticationEnabled {
            if configuration.username.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Username is required when authentication is enabled"
            }
            if configuration.password?.isEmpty != false {
                return "Password is required when authentication is enabled"
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
        if isIPv4(trimmed) || isIPv6(trimmed) {
            return nil
        }
        if !isValidHostname(trimmed) {
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

    public static func isIPv4(_ string: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, string, &address) == 1
    }

    public static func isIPv6(_ string: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, string, &address) == 1
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
            // Middle characters: alphanumerics, hyphen, underscore.
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

    public init(configurations: [ProxyConfiguration] = [], errors: [ProxyYAMLImportError] = []) {
        self.configurations = configurations
        self.errors = errors
    }

    public var validCount: Int { configurations.count }
    public var errorCount: Int { errors.count }
}
