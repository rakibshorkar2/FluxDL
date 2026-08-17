import XCTest
@testable import FluxDL

final class ProxyConfigurationTests: XCTestCase {

    // MARK: - Host validation

    func testValidSOCKS5Configuration() {
        let configuration = ProxyConfiguration(
            name: "Test",
            type: .socks5,
            host: "192.168.1.10",
            port: 1080
        )
        XCTAssertNil(ProxyConfigurationValidator.validate(configuration))
    }

    func testValidHostnameConfiguration() {
        XCTAssertNil(ProxyConfigurationValidator.validateHost("example.com"))
        XCTAssertNil(ProxyConfigurationValidator.validateHost("sub.example-proxy.com"))
        XCTAssertNil(ProxyConfigurationValidator.validateHost("localhost"))
        XCTAssertNil(ProxyConfigurationValidator.validateHost("127.0.0.1"))
        XCTAssertNil(ProxyConfigurationValidator.validateHost("::1"))
        XCTAssertNil(ProxyConfigurationValidator.validateHost("2001:db8::1"))
    }

    func testEmptyHostIsInvalid() {
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost(""))
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("   "))
    }

    func testHostWithSpacesIsInvalid() {
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("my proxy.com"))
    }

    func testHostWithInvalidCharactersIsInvalid() {
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("proxy!site"))
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("proxy/site"))
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("bad_host_!!!"))
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("under_score."))
    }

    func testHostnameLabelLengthLimits() {
        let maxLabel = String(repeating: "a", count: 63)
        XCTAssertNil(ProxyConfigurationValidator.validateHost("\(maxLabel).com"))

        let tooLongLabel = String(repeating: "a", count: 64)
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("\(tooLongLabel).com"))

        let tooLongHostname = String(repeating: "a", count: 254)
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost(tooLongHostname))
    }

    func testHostnameEdgeCases() {
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("-bad.com"))
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("bad-.com"))
        XCTAssertNotNil(ProxyConfigurationValidator.validateHost("bad..com"))
    }

    // MARK: - Port validation

    func testValidPorts() {
        XCTAssertNil(ProxyConfigurationValidator.validatePort(1))
        XCTAssertNil(ProxyConfigurationValidator.validatePort(1080))
        XCTAssertNil(ProxyConfigurationValidator.validatePort(65535))
    }

    func testInvalidPorts() {
        XCTAssertNotNil(ProxyConfigurationValidator.validatePort(0))
        XCTAssertNotNil(ProxyConfigurationValidator.validatePort(65536))
        XCTAssertNotNil(ProxyConfigurationValidator.validatePort(-1))
        XCTAssertNotNil(ProxyConfigurationValidator.validatePort(-1080))
    }

    // MARK: - Authentication

    func testAuthenticationRequiresUsernameAndPassword() {
        let missingPassword = ProxyConfiguration(
            name: "Auth",
            host: "example.com",
            port: 1080,
            authenticationEnabled: true,
            username: "user",
            password: nil
        )
        XCTAssertNotNil(ProxyConfigurationValidator.validate(missingPassword))

        let missingUsername = ProxyConfiguration(
            name: "Auth",
            host: "example.com",
            port: 1080,
            authenticationEnabled: true,
            username: "",
            password: "pass"
        )
        XCTAssertNotNil(ProxyConfigurationValidator.validate(missingUsername))

        let complete = ProxyConfiguration(
            name: "Auth",
            host: "example.com",
            port: 1080,
            authenticationEnabled: true,
            username: "user",
            password: "pass"
        )
        XCTAssertNil(ProxyConfigurationValidator.validate(complete))
    }

    func testAuthenticationDisabledDoesNotRequireCredentials() {
        let configuration = ProxyConfiguration(
            name: "Open",
            host: "example.com",
            port: 1080,
            authenticationEnabled: false
        )
        XCTAssertNil(ProxyConfigurationValidator.validate(configuration))
        XCTAssertFalse(configuration.requiresAuthentication)
    }

    // MARK: - Codable security

    func testPasswordIsNeverPersistedByCodable() throws {
        let configuration = ProxyConfiguration(
            name: "Secret",
            host: "example.com",
            port: 1080,
            authenticationEnabled: true,
            username: "user",
            password: "hunter2"
        )
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: data)

        XCTAssertEqual(decoded.name, configuration.name)
        XCTAssertEqual(decoded.host, configuration.host)
        XCTAssertEqual(decoded.port, configuration.port)
        XCTAssertNil(decoded.password, "Password must never survive Codable round-trips.")
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("hunter2") == false)
    }

    func testProfileCodableRoundTripWithoutPassword() throws {
        let configuration = ProxyConfiguration(
            name: "Secret",
            host: "example.com",
            port: 1080,
            authenticationEnabled: true,
            username: "user",
            password: "hunter2"
        )
        let profile = ProxyProfile(
            configuration: configuration,
            lastTestedAt: Date(),
            lastLatencyMs: 42,
            lastConnectionState: .connected
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ProxyProfile.self, from: data)

        XCTAssertNil(decoded.configuration.password)
        XCTAssertEqual(decoded.lastLatencyMs, 42)
        XCTAssertEqual(decoded.lastConnectionState, .connected)
        XCTAssertEqual(decoded.id, profile.id)
    }

    // MARK: - Type model

    func testProxyTypeModel() {
        XCTAssertEqual(ProxyType.allCases, [.http, .https, .socks4, .socks5])
        XCTAssertEqual(ProxyType.socks5.rawValue, "socks5")
        XCTAssertEqual(ProxyType.http.rawValue, "http")
        XCTAssertEqual(ProxyType.https.rawValue, "https")
        XCTAssertEqual(ProxyType.socks4.rawValue, "socks4")
        XCTAssertEqual(ProxyType.socks5.displayName, "SOCKS5")
        XCTAssertTrue(ProxyType.http.supportsUsernamePasswordAuth)
        XCTAssertTrue(ProxyType.https.supportsUsernamePasswordAuth)
        XCTAssertTrue(ProxyType.socks5.supportsUsernamePasswordAuth)
        XCTAssertFalse(ProxyType.socks4.supportsUsernamePasswordAuth)
    }

    func testAllSupportedTypesValidate() {
        for type in ProxyType.allCases {
            let configuration = ProxyConfiguration(
                name: "\(type.displayName) Entry",
                type: type,
                host: "proxy.example.com",
                port: 1080
            )
            XCTAssertNil(ProxyConfigurationValidator.validate(configuration), "\(type) should validate")
        }
    }

    // MARK: - Fingerprint

    func testFingerprintIsStableAndPasswordIndependent() {
        let a = ProxyConfiguration(name: "A", host: "  Proxy.EXAMPLE.com ", port: 1080, username: "user")
        let b = ProxyConfiguration(name: "B", host: "proxy.example.com", port: 1080, username: "user", password: "different")
        XCTAssertEqual(a.fingerprint, b.fingerprint)

        let differentPort = ProxyConfiguration(name: "C", host: "proxy.example.com", port: 1081, username: "user")
        XCTAssertNotEqual(a.fingerprint, differentPort.fingerprint)
    }

    // MARK: - URI parsing

    func testURIParsingAllSchemes() throws {
        let socks5 = try XCTUnwrap(ProxyURIParser.parse("socks5://user:pass@proxy.example.com:1080"))
        XCTAssertEqual(socks5.type, .socks5)
        XCTAssertEqual(socks5.host, "proxy.example.com")
        XCTAssertEqual(socks5.port, 1080)
        XCTAssertTrue(socks5.authenticationEnabled)
        XCTAssertEqual(socks5.password, "pass")

        let socks5h = try XCTUnwrap(ProxyURIParser.parse("socks5h://proxy.example.com:1080"))
        XCTAssertEqual(socks5h.type, .socks5)
        XCTAssertFalse(socks5h.authenticationEnabled)

        let socks4 = try XCTUnwrap(ProxyURIParser.parse("socks4://user@proxy.example.com:1081"))
        XCTAssertEqual(socks4.type, .socks4)
        XCTAssertEqual(socks4.port, 1081)
        XCTAssertFalse(socks4.authenticationEnabled, "SOCKS4 has no password channel")

        let http = try XCTUnwrap(ProxyURIParser.parse("http://proxy.example.com:8080"))
        XCTAssertEqual(http.type, .http)
        XCTAssertEqual(http.port, 8080)

        let https = try XCTUnwrap(ProxyURIParser.parse("https://proxy.example.com:8443"))
        XCTAssertEqual(https.type, .https)
    }

    func testURIParsingIPv6Brackets() throws {
        let configuration = try XCTUnwrap(ProxyURIParser.parse("socks5://[2001:db8::1]:1080"))
        XCTAssertEqual(configuration.host, "2001:db8::1")
        XCTAssertEqual(configuration.displayHost, "[2001:db8::1]")
        XCTAssertEqual(configuration.hostAndPortString, "[2001:db8::1]:1080")
    }

    func testURIParsingDefaultsPorts() throws {
        XCTAssertEqual(try XCTUnwrap(ProxyURIParser.parse("http://proxy.example.com")).port, 8080)
        XCTAssertEqual(try XCTUnwrap(ProxyURIParser.parse("socks5://proxy.example.com")).port, 1080)
    }

    func testInvalidURIsAreRejected() {
        XCTAssertNil(ProxyURIParser.parse("vmess://proxy.example.com:443"))
        XCTAssertNil(ProxyURIParser.parse("trojan://proxy.example.com"))
        XCTAssertNil(ProxyURIParser.parse("proxy.example.com:1080"))
        XCTAssertNil(ProxyURIParser.parse(""))
        XCTAssertNil(ProxyURIParser.parse("socks5://"))
    }
}
