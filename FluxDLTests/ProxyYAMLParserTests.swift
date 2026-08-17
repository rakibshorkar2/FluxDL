import XCTest
@testable import FluxDL

final class ProxyYAMLParserTests: XCTestCase {

    // MARK: - Valid documents

    func testValidClashStyleYAMLWithMultipleProxies() throws {
        let yaml = """
        proxies:
          - name: Proxy 1
            type: socks5
            server: 127.0.0.1
            port: 1080

          - name: Proxy 2
            type: socks5
            server: example.com
            port: 1080
            username: user
            password: pass
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 2)
        XCTAssertEqual(result.errorCount, 0)

        let first = result.configurations[0]
        XCTAssertEqual(first.name, "Proxy 1")
        XCTAssertEqual(first.type, .socks5)
        XCTAssertEqual(first.host, "127.0.0.1")
        XCTAssertEqual(first.port, 1080)
        XCTAssertFalse(first.authenticationEnabled)

        let second = result.configurations[1]
        XCTAssertEqual(second.name, "Proxy 2")
        XCTAssertEqual(second.host, "example.com")
        XCTAssertEqual(second.port, 1080)
        XCTAssertTrue(second.authenticationEnabled)
        XCTAssertEqual(second.username, "user")
        XCTAssertEqual(second.password, "pass")
    }

    func testSingleProxyMappingForm() throws {
        let yaml = """
        proxy:
          name: Single
          type: socks5
          server: proxy.example.net
          port: 8080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.configurations.first?.name, "Single")
        XCTAssertEqual(result.configurations.first?.host, "proxy.example.net")
        XCTAssertEqual(result.configurations.first?.port, 8080)
    }

    func testRootLevelSingleProxyForm() throws {
        let yaml = """
        name: Root Proxy
        type: socks5
        server: 10.0.0.5
        port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.configurations.first?.name, "Root Proxy")
    }

    func testRootSequenceForm() throws {
        let yaml = """
        - name: A
          type: socks5
          server: a.example.com
          port: 1080
        - name: B
          type: socks5
          server: b.example.com
          port: 1081
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 2)
    }

    func testCommentsAreIgnored() throws {
        let yaml = """
        # Clash-style config
        proxies: # the list
          - name: C # name comment
            type: socks5
            server: 127.0.0.1
            port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.configurations.first?.name, "C")
    }

    func testQuotedValues() throws {
        let yaml = """
        proxies:
          - name: "Quoted Proxy"
            type: socks5
            server: 'example.com'
            port: 1080
            username: "user:name"
            password: "p@ss"
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.configurations.first?.name, "Quoted Proxy")
        XCTAssertEqual(result.configurations.first?.username, "user:name")
    }

    func testMissingNameFallsBackToServerPort() throws {
        let yaml = """
        proxies:
          - type: socks5
            server: fallback.example.com
            port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.configurations.first?.name, "fallback.example.com:1080")
    }

    func testHostKeyAcceptedAsAlias() throws {
        let yaml = """
        proxies:
          - name: Alias
            type: socks5
            host: alias.example.com
            port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.configurations.first?.host, "alias.example.com")
    }

    // MARK: - Errors

    func testMalformedYAMLThrows() {
        let yaml = """
        proxies:
          - name: Broken
            type socks5
        """
        XCTAssertThrowsError(try ProxyYAMLParser.extractProxies(from: yaml)) { error in
            XCTAssertTrue(error is ProxyYAMLParserError)
            XCTAssertTrue((error as? ProxyYAMLParserError)?.userMessage.contains("Invalid YAML") == true)
        }
    }

    func testTabsInIndentationThrow() {
        let yaml = """
        proxies:
        \t- name: Tabbed
        \t  type: socks5
        \t  server: example.com
        \t  port: 1080
        """
        XCTAssertThrowsError(try ProxyYAMLParser.extractProxies(from: yaml))
    }

    func testEmptyDocumentThrows() {
        XCTAssertThrowsError(try ProxyYAMLParser.extractProxies(from: ""))
        XCTAssertThrowsError(try ProxyYAMLParser.extractProxies(from: "   \n\n# nothing here\n"))
    }

    func testDocumentWithoutProxiesThrows() {
        let yaml = """
        some:
          other: content
        """
        XCTAssertThrowsError(try ProxyYAMLParser.extractProxies(from: yaml))
    }

    func testUnsupportedTypeIsReportedPerEntry() throws {
        let yaml = """
        proxies:
          - name: Good
            type: socks5
            server: example.com
            port: 1080
          - name: Bad
            type: vmess
            server: example.com
            port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.errorCount, 1)
        XCTAssertEqual(result.errors.first?.displayName, "Bad")
        XCTAssertTrue(result.errors.first?.message.contains("Unsupported proxy type") == true)
        XCTAssertEqual(result.configurations.first?.name, "Good")
    }

    // MARK: - All supported types

    func testAllSupportedTypesParse() throws {
        let yaml = """
        proxies:
          - name: HTTP Entry
            type: http
            server: example.com
            port: 8080
          - name: HTTPS Entry
            type: https
            server: example.com
            port: 8443
          - name: SOCKS4 Entry
            type: socks4
            server: 10.0.0.7
            port: 1081
          - name: SOCKS5 Entry
            type: socks5
            server: 10.0.0.8
            port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 4)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertEqual(result.configurations.map(\.type), [.http, .https, .socks4, .socks5])
    }

    func testTypeAliasesNormalize() throws {
        let yaml = """
        proxies:
          - name: SOCKS4a
            type: socks4a
            server: example.com
            port: 1080
          - name: SOCKS5h
            type: socks5h
            server: example.com
            port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 2)
        XCTAssertEqual(result.configurations.map(\.type), [.socks4, .socks5])
    }

    func testSOCKS4IgnoresPasswordField() throws {
        let yaml = """
        proxies:
          - name: S4
            type: socks4
            server: example.com
            port: 1080
            username: user
            password: pass
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertFalse(result.configurations.first?.authenticationEnabled == true)
    }

    func testDuplicateFingerprintsAreDeduplicated() throws {
        let yaml = """
        proxies:
          - name: One
            type: socks5
            server: proxy.example.com
            port: 1080
            username: user
          - name: Two (different password)
            type: socks5
            server: proxy.example.com
            port: 1080
            username: user
            password: other
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
    }

    // MARK: - URI-style entries

    func testURIStyleEntriesParse() throws {
        let yaml = """
        proxies:
          - socks5://user:pass@proxy.example.com:1080
          - https://proxy.example.com:8443
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 2)
        XCTAssertEqual(result.configurations.map(\.type), [.socks5, .https])
        XCTAssertEqual(result.configurations.first?.username, "user")
    }

    func testInvalidURIToPlainTextIsAnError() throws {
        let yaml = """
        proxies:
          - this is not a uri
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 0)
        XCTAssertEqual(result.errorCount, 1)
        XCTAssertTrue(result.errors.first?.message.contains("Invalid proxy URI") == true)
    }

    func testMissingRequiredFieldsAreReported() throws {
        let yaml = """
        proxies:
          - name: No Type
            server: example.com
            port: 1080
          - name: No Server
            type: socks5
            port: 1080
          - name: No Port
            type: socks5
            server: example.com
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 0)
        XCTAssertEqual(result.errorCount, 3)
        XCTAssertTrue(result.errors.contains { $0.message.contains("type") })
        XCTAssertTrue(result.errors.contains { $0.message.contains("server") })
        XCTAssertTrue(result.errors.contains { $0.message.contains("port") })
    }

    func testInvalidPortIsReported() throws {
        let yaml = """
        proxies:
          - name: Bad Port
            type: socks5
            server: example.com
            port: 99999
          - name: Text Port
            type: socks5
            server: example.com
            port: eight
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 0)
        XCTAssertEqual(result.errorCount, 2)
    }

    func testMissingUsernameOrPasswordIsReported() throws {
        let yaml = """
        proxies:
          - name: User Only
            type: socks5
            server: example.com
            port: 1080
            username: user
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 0)
        XCTAssertEqual(result.errorCount, 1)
        XCTAssertTrue(result.errors.first?.message.contains("password") == true)
    }

    func testInvalidHostIsReported() throws {
        let yaml = """
        proxies:
          - name: Bad Host
            type: socks5
            server: not a valid host!!
            port: 1080
        """
        let result = try ProxyYAMLParser.extractProxies(from: yaml)
        XCTAssertEqual(result.validCount, 0)
        XCTAssertEqual(result.errorCount, 1)
    }

    // MARK: - Node parsing

    func testScalarTyping() throws {
        XCTAssertEqual(try ProxyYAMLParser.parse("a: 1"), .mapping(["a": .scalar("1")]))
        XCTAssertEqual(try ProxyYAMLParser.parse("a: true"), .mapping(["a": .scalar("true")]))
        XCTAssertEqual(try ProxyYAMLParser.parse("a: null"), .mapping(["a": .null]))
        XCTAssertEqual(try ProxyYAMLParser.parse("a: ~"), .mapping(["a": .null]))
        XCTAssertEqual(try ProxyYAMLParser.parse("a: 'quoted'"), .mapping(["a": .scalar("quoted")]))
        XCTAssertEqual(try ProxyYAMLParser.parse("a: \"dq\""), .mapping(["a": .scalar("dq")]))
    }
}
