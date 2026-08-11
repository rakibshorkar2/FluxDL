import Foundation
import Yams

// MARK: - YAMLNode
//
// Protocol-agnostic representation of a parsed YAML document, converted from
// the Yams node tree. Kept so existing consumers (and tests) can walk the
// document without depending on Yams types directly.

public enum YAMLNode: Equatable, Sendable {
    case scalar(String)
    case mapping([String: YAMLNode])
    case sequence([YAMLNode])
    case null

    public var asString: String? {
        switch self {
        case .scalar(let value): return value
        default: return nil
        }
    }

    public var asInt: Int? {
        guard case .scalar(let value) = self else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public struct ProxyYAMLParserError: Error, Equatable, Sendable {
    public let line: Int?
    public let message: String

    public init(line: Int?, message: String) {
        self.line = line
        self.message = message
    }

    public var userMessage: String {
        if let line = line {
            return "Invalid YAML (line \(line)): \(message)"
        }
        return "Invalid YAML: \(message)"
    }
}

// MARK: - ProxyYAMLParser
//
// Parsing is delegated to Yams (a maintained, standards-compliant YAML
// parser). Indentation handling, quoting, comments, scalar typing and
// multi-document input are Yams' responsibility — this is not a fragile
// string-splitting parser.

public enum ProxyYAMLParser {

    /// Maps a Yams `Any` tree into our `YAMLNode` type.
    private static func node(from value: Any?) -> YAMLNode {
        guard let value, !(value is NSNull) else { return .null }

        if let dictionary = value as? [AnyHashable: Any] {
            var mapping: [String: YAMLNode] = [:]
            for (key, child) in dictionary {
                mapping[String(describing: key)] = node(from: child)
            }
            return .mapping(mapping)
        }
        if let array = value as? [Any] {
            return .sequence(array.map { node(from: $0) })
        }
        if let string = value as? String {
            return .scalar(string)
        }
        if let integer = value as? Int {
            return .scalar(String(integer))
        }
        if let double = value as? Double {
            return .scalar(String(double))
        }
        if let bool = value as? Bool {
            return .scalar(bool ? "true" : "false")
        }
        return .scalar(String(describing: value))
    }

    /// Loads a YAML document with Yams.
    private static func loadYams(_ input: String) throws -> Any? {
        try Yams.load(yaml: input)
    }

    /// Tabs are never valid YAML indentation. Rejecting them up front (a
    /// simple lint, not parsing) keeps error messages deterministic.
    private static func assertNoTabIndentation(in input: String) throws {
        for (offset, rawLine) in input.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            if line.first == "\t" {
                throw ProxyYAMLParserError(line: offset + 1, message: "tabs are not allowed for indentation")
            }
        }
    }

    // MARK: - Public API

    /// Parses a YAML document into a `YAMLNode` tree.
    public static func parse(_ input: String) throws -> YAMLNode {
        try assertNoTabIndentation(in: input)
        let value: Any?
        do {
            value = try loadYams(input)
        } catch {
            throw ProxyYAMLParserError(line: nil, message: String(describing: error))
        }
        guard let value else {
            throw ProxyYAMLParserError(line: nil, message: "file is empty")
        }
        let root = node(from: value)
        if root.isNull {
            throw ProxyYAMLParserError(line: nil, message: "file is empty")
        }
        return root
    }

    /// Parses a YAML document and extracts proxy configurations.
    /// Valid entries are returned as configurations; invalid entries are
    /// reported with a human-readable reason. Never throws for individual
    /// bad proxy entries — only for documents that cannot be parsed at all.
    public static func extractProxies(from input: String) throws -> ProxyYAMLImportResult {
        let root = try parse(input)

        let proxyNodes: [YAMLNode]
        switch root {
        case .mapping(let dict):
            if let proxiesNode = dict["proxies"] {
                guard case .sequence(let sequence) = proxiesNode else {
                    throw ProxyYAMLParserError(line: nil, message: "'proxies' must be a list")
                }
                proxyNodes = sequence
            } else if let proxyNode = dict["proxy"] {
                proxyNodes = [proxyNode]
            } else if dict.keys.contains("server") || dict.keys.contains("host")
                        || dict.keys.contains("type") || dict.keys.contains("port") {
                proxyNodes = [.mapping(dict)]
            } else {
                throw ProxyYAMLParserError(line: nil, message: "no proxy configuration found in YAML")
            }
        case .sequence(let sequence):
            proxyNodes = sequence
        case .scalar(let scalar):
            guard ProxyURIParser.parse(scalar) != nil else {
                throw ProxyYAMLParserError(line: nil, message: "no proxy configuration found in YAML")
            }
            proxyNodes = [.scalar(scalar)]
        case .null:
            throw ProxyYAMLParserError(line: nil, message: "file is empty")
        }

        var result = ProxyYAMLImportResult()
        var fingerprints = Set<String>()
        for (index, node) in proxyNodes.enumerated() {
            let outcome = configuration(from: node, index: index)
            if let configuration = outcome.configuration {
                if fingerprints.insert(configuration.fingerprint).inserted {
                    result.configurations.append(configuration)
                } else {
                    result.duplicateCount += 1
                }
            } else if let error = outcome.error {
                result.errors.append(error)
            }
        }
        return result
    }

    // MARK: - Proxy extraction

    private static func configuration(
        from node: YAMLNode,
        index: Int
    ) -> (configuration: ProxyConfiguration?, error: ProxyYAMLImportError?) {

        // URI-style entry: a plain scalar string such as
        // socks5://user:pass@host:port
        if case .scalar(let uri) = node {
            if let parsed = ProxyURIParser.parse(uri) {
                return (parsed, nil)
            }
            let display = uri.count > 40 ? String(uri.prefix(40)) + "…" : uri
            return (nil, ProxyYAMLImportError(displayName: nil, message: "Invalid proxy URI: \(display)"))
        }

        guard case .mapping(let dict) = node else {
            return (nil, ProxyYAMLImportError(displayName: nil, message: "proxy entry \(index + 1) is not a mapping"))
        }

        let name = nonEmpty(dict["name"]?.asString)
        let typeRaw = dict["type"]?.asString?.trimmingCharacters(in: .whitespaces).lowercased()
        let server = nonEmpty(dict["server"]?.asString) ?? nonEmpty(dict["host"]?.asString)
        let portValue = dict["port"]?.asInt
        let username = nonEmpty(dict["username"]?.asString)
        let password = nonEmpty(dict["password"]?.asString)
        // Metadata keys used by common proxy-list formats; folded into the
        // generated name so imported entries keep their provenance.
        let country = nonEmpty(dict["country"]?.asString) ?? nonEmpty(dict["region"]?.asString)
        let note = nonEmpty(dict["note"]?.asString) ?? nonEmpty(dict["remarks"]?.asString)

        // ── Type mapping (socks5h / socks4a alias onto the base protocols) ──
        let type: ProxyType
        if let typeRaw {
            switch typeRaw {
            case "http":               type = .http
            case "https":              type = .https
            case "socks4", "socks4a":  type = .socks4
            case "socks5", "socks5h":  type = .socks5
            default:
                return (nil, ProxyYAMLImportError(displayName: name, message: "Unsupported proxy type: \(typeRaw)"))
            }
        } else {
            return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: type"))
        }

        guard let server, !server.isEmpty else {
            return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: server"))
        }
        if let hostIssue = ProxyConfigurationValidator.validateHost(server) {
            return (nil, ProxyYAMLImportError(displayName: name, message: hostIssue))
        }

        guard let portValue else {
            return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: port"))
        }
        if let portIssue = ProxyConfigurationValidator.validatePort(portValue) {
            return (nil, ProxyYAMLImportError(displayName: name, message: portIssue))
        }

        let authenticationEnabled: Bool
        if type == .socks4 {
            // SOCKS4 accepts an optional USERID; it has no password channel.
            authenticationEnabled = false
            if username != nil && password != nil {
                return (nil, ProxyYAMLImportError(displayName: name, message: "SOCKS4 proxies do not support passwords"))
            }
        } else if username != nil || password != nil {
            if username == nil || password == nil {
                let missing = username == nil ? "username" : "password"
                return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: \(missing)"))
            }
            authenticationEnabled = true
        } else {
            authenticationEnabled = false
        }

        let finalName = name ?? {
            var composed = "\(ProxyConfigurationValidator.bracketedHost(server)):\(portValue)"
            if let country { composed += " \u{00B7} \(country)" }
            if let note { composed += " (\(note))" }
            return composed
        }()
        return (
            ProxyConfiguration(
                name: finalName,
                type: type,
                host: server,
                port: portValue,
                authenticationEnabled: authenticationEnabled,
                username: username ?? "",
                password: password
            ),
            nil
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}