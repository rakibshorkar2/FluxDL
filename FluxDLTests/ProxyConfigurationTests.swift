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

    func testProxyTypeExtensible() {
        XCTAssertEqual(ProxyType.socks5.rawValue, "socks5")
        XCTAssertEqual(ProxyType.allCases, [.socks5])
        XCTAssertEqual(ProxyType.socks5.displayName, "SOCKS5")
    }
}
