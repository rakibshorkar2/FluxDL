import Foundation

// MARK: - ProxyYAMLParser
//
// A small, self-contained YAML parser covering the subset of YAML that
// proxy configuration files commonly use (Clash-style and single-proxy
// documents). It performs REAL parsing: indentation-aware nested maps and
// sequences, quoted scalars, comments, and scalar typing.
//
// Supported syntax:
//   - comments (`#` up to end of line, outside quotes)
//   - mappings       `key: value`
//   - sequences      `- item` / `- key: value`
//   - nested blocks via indentation (spaces only)
//   - plain, single-quoted and double-quoted scalars

public enum YAMLNode: Equatable, Sendable {
    case scalar(String)
    case mapping([String: YAMLNode])
    case sequence([YAMLNode])
    case null

    public var asString: String? {
        switch self {
        case .scalar(let value): return value
        case .null: return nil
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

public enum ProxyYAMLParser {

    // MARK: - Public API

    /// Parses a YAML document into a `YAMLNode` tree.
    public static func parse(_ input: String) throws -> YAMLNode {
        let lines = try preprocess(input)
        guard !lines.isEmpty else {
            throw ProxyYAMLParserError(line: nil, message: "file is empty")
        }
        let (root, next) = try parseBlock(lines, from: 0, indent: lines[0].indent)
        guard next == lines.count else {
            // Trailing content at a shallower indentation than the root.
            throw ProxyYAMLParserError(line: lines[next].number, message: "unexpected content")
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
                guard case .mapping = proxyNode else {
                    throw ProxyYAMLParserError(line: nil, message: "'proxy' must be a mapping")
                }
                proxyNodes = [proxyNode]
            } else if dict.keys.contains("server") || dict.keys.contains("host") || dict.keys.contains("type") {
                proxyNodes = [.mapping(dict)]
            } else {
                throw ProxyYAMLParserError(line: nil, message: "no proxy configuration found in YAML")
            }
        case .sequence(let sequence):
            proxyNodes = sequence
        case .null:
            throw ProxyYAMLParserError(line: nil, message: "file is empty")
        default:
            throw ProxyYAMLParserError(line: nil, message: "no proxy configuration found in YAML")
        }

        var result = ProxyYAMLImportResult()
        for (index, node) in proxyNodes.enumerated() {
            let outcome = configuration(from: node, index: index)
            if let configuration = outcome.configuration {
                result.configurations.append(configuration)
            } else if let error = outcome.error {
                result.errors.append(error)
            }
        }
        return result
    }

    // MARK: - Proxy extraction

    private static func configuration(from node: YAMLNode, index: Int) -> (configuration: ProxyConfiguration?, error: ProxyYAMLImportError?) {
        guard case .mapping(let dict) = node else {
            return (nil, ProxyYAMLImportError(displayName: nil, message: "proxy entry \(index + 1) is not a mapping"))
        }

        let name = nonEmpty(dict["name"]?.asString)
        let type = dict["type"]?.asString?.trimmingCharacters(in: .whitespaces).lowercased()
        let server = nonEmpty(dict["server"]?.asString) ?? nonEmpty(dict["host"]?.asString)
        let portValue = dict["port"]?.asInt
        let username = nonEmpty(dict["username"]?.asString)
        let password = nonEmpty(dict["password"]?.asString)

        // ── Field validation ─────────────────────────────────────────────
        if let type = type {
            guard type == ProxyType.socks5.rawValue else {
                return (nil, ProxyYAMLImportError(displayName: name, message: "Unsupported proxy type: \(type)"))
            }
        } else {
            return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: type"))
        }

        guard let server = server, !server.isEmpty else {
            return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: server"))
        }
        if let hostIssue = ProxyConfigurationValidator.validateHost(server) {
            return (nil, ProxyYAMLImportError(displayName: name, message: hostIssue))
        }

        guard let portValue = portValue else {
            return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: port"))
        }
        if let portIssue = ProxyConfigurationValidator.validatePort(portValue) {
            return (nil, ProxyYAMLImportError(displayName: name, message: portIssue))
        }

        let authenticationEnabled = username != nil || password != nil
        if authenticationEnabled && (username == nil || password == nil) {
            let missing = username == nil ? "username" : "password"
            return (nil, ProxyYAMLImportError(displayName: name, message: "Missing required YAML field: \(missing)"))
        }

        let finalName = name ?? "\(server):\(portValue)"
        return (
            ProxyConfiguration(
                name: finalName,
                type: .socks5,
                host: server,
                port: portValue,
                authenticationEnabled: authenticationEnabled,
                username: username ?? "",
                password: password
            ),
            nil
        )
    }

    // MARK: - Preprocessing

    private struct Line {
        let number: Int
        let indent: Int
        let content: String
    }

    private static func preprocess(_ input: String) throws -> [Line] {
        let rawLines = input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        var result: [Line] = []
        for (index, raw) in rawLines.enumerated() {
            let lineNumber = index + 1
            let line = String(raw)

            // Tabs are not valid for indentation in the supported subset.
            if let firstTab = line.firstIndex(of: "\t") {
                let beforeTab = line[..<firstTab]
                if !beforeTab.trimmingCharacters(in: .whitespaces).isEmpty || !beforeTab.isEmpty {
                    throw ProxyYAMLParserError(line: lineNumber, message: "tabs are not allowed for indentation")
                }
            }

            var indent = 0
            var contentStart = line.startIndex
            while contentStart < line.endIndex {
                let char = line[contentStart]
                if char == " " {
                    indent += 1
                    contentStart = line.index(after: contentStart)
                } else {
                    break
                }
            }

            var content = String(line[contentStart...])
            content = stripComment(from: content)

            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            result.append(Line(number: lineNumber, indent: indent, content: trimmed))
        }
        return result
    }

    /// Removes a `#` comment that is not inside single or double quotes.
    private static func stripComment(from line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        for (offset, character) in line.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inDoubleQuote {
                escaped = true
                continue
            }
            switch character {
            case "'":
                if !inDoubleQuote { inSingleQuote.toggle() }
            case "\"":
                if !inSingleQuote { inDoubleQuote.toggle() }
            case "#":
                if !inSingleQuote && !inDoubleQuote {
                    return String(line.prefix(offset))
                }
            default:
                break
            }
        }
        return line
    }

    // MARK: - Recursive descent

    private static func parseBlock(_ lines: [Line], from index: Int, indent: Int) throws -> (YAMLNode, Int) {
        guard index < lines.count, lines[index].indent == indent else {
            return (.null, index)
        }
        if lines[index].content == "-" || lines[index].content.hasPrefix("- ") {
            return try parseSequence(lines, from: index, indent: indent)
        }
        return try parseMapping(lines, from: index, indent: indent)
    }

    private static func parseMapping(_ lines: [Line], from index: Int, indent: Int) throws -> (YAMLNode, Int) {
        var dict: [String: YAMLNode] = [:]
        var i = index
        while i < lines.count {
            guard lines[i].indent == indent else { break }

            guard let (key, value) = splitKeyValue(lines[i].content) else {
                throw ProxyYAMLParserError(line: lines[i].number, message: "expected 'key: value'")
            }
            let keyString = try unquote(key).trimmingCharacters(in: .whitespaces)
            guard !keyString.isEmpty else {
                throw ProxyYAMLParserError(line: lines[i].number, message: "empty key")
            }

            var node: YAMLNode = .null
            if let value = value {
                node = try scalarNode(value, line: lines[i].number)
            }
            i += 1

            if i < lines.count, lines[i].indent > indent {
                let (child, next) = try parseBlock(lines, from: i, indent: lines[i].indent)
                if value == nil {
                    node = child
                } else if !child.isNull {
                    throw ProxyYAMLParserError(
                        line: lines[i].number,
                        message: "unexpected indented block after '\(keyString): \(value ?? "")'"
                    )
                }
                i = next
            }

            dict[keyString] = node
        }
        return (.mapping(dict), i)
    }

    private static func parseSequence(_ lines: [Line], from index: Int, indent: Int) throws -> (YAMLNode, Int) {
        var items: [YAMLNode] = []
        var i = index
        while i < lines.count {
            guard lines[i].indent == indent else { break }

            let content = lines[i].content
            guard content == "-" || content.hasPrefix("- ") else { break }

            let rest = content == "-" ? "" : String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            i += 1

            if rest.isEmpty {
                // Item is a nested block on the following lines.
                if i < lines.count, lines[i].indent > indent {
                    let (node, next) = try parseBlock(lines, from: i, indent: lines[i].indent)
                    items.append(node)
                    i = next
                } else {
                    items.append(.null)
                }
                continue
            }

            if let (key, value) = splitKeyValue(rest) {
                // Inline mapping item: `- key: value`, possibly continued by
                // deeper-indented keys belonging to the same item.
                var itemDict: [String: YAMLNode] = [:]
                let keyString = try unquote(key).trimmingCharacters(in: .whitespaces)
                if let value = value {
                    itemDict[keyString] = try scalarNode(value, line: lines[i - 1].number)
                } else {
                    itemDict[keyString] = .null
                }

                if i < lines.count, lines[i].indent > indent {
                    let (node, next) = try parseBlock(lines, from: i, indent: lines[i].indent)
                    if case .mapping(let nested) = node {
                        for (nestedKey, nestedValue) in nested {
                            itemDict[nestedKey] = nestedValue
                        }
                    } else if !node.isNull {
                        throw ProxyYAMLParserError(
                            line: lines[i].number,
                            message: "unexpected nested list inside proxy entry"
                        )
                    }
                    i = next
                }
                items.append(.mapping(itemDict))
            } else {
                items.append(try scalarNode(rest, line: lines[i - 1].number))
            }
        }
        return (.sequence(items), i)
    }

    // MARK: - Scalars

    /// Splits `key: value`. Returns nil when the line is not a key/value pair.
    private static func splitKeyValue(_ content: String) -> (String, String?)? {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        for (offset, character) in content.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inDoubleQuote {
                escaped = true
                continue
            }
            switch character {
            case "'":
                if !inDoubleQuote { inSingleQuote.toggle() }
            case "\"":
                if !inSingleQuote { inDoubleQuote.toggle() }
            case ":":
                if !inSingleQuote && !inDoubleQuote {
                    let key = String(content.prefix(offset))
                    let value = String(content.dropFirst(offset + 1)).trimmingCharacters(in: .whitespaces)
                    return (key, value.isEmpty ? nil : value)
                }
            default:
                break
            }
        }
        return nil
    }

    private static func scalarNode(_ raw: String, line: Int) throws -> YAMLNode {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .null }
        let lower = trimmed.lowercased()
        if trimmed == "~" || lower == "null" { return .null }
        return .scalar(try unquote(trimmed))
    }

    /// Removes surrounding quotes and resolves the supported escape sequences.
    private static func unquote(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.first == "'", trimmed.last == "'" {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        if trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" {
            let inner = String(trimmed.dropFirst().dropLast())
            var result = ""
            var iterator = inner.makeIterator()
            var pendingEscape = false
            while let character = iterator.next() {
                if pendingEscape {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    case "u":
                        var hex = ""
                        for _ in 0..<4 {
                            if let hexChar = iterator.next() { hex.append(hexChar) }
                        }
                        if let codePoint = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(codePoint) {
                            result.unicodeScalars.append(scalar)
                        }
                    default:
                        result.append(character)
                    }
                    pendingEscape = false
                } else if character == "\\" {
                    pendingEscape = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        return trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
