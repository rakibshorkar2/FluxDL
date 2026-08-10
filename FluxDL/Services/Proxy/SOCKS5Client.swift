import Foundation
import Network

// MARK: - SOCKS5Client
//
// A real SOCKS5 (RFC 1928 / RFC 1929) client built on the shared proxy
// transport (`ProxyStream` / `SOCKSHandshake`). Performs the actual SOCKS5
// handshake against a proxy and measures the total elapsed time:
//
//   1. TCP connect to the proxy server
//   2. Greeting:  0x05, NMETHODS, METHODS...
//   3. (optional) Username/Password authentication (RFC 1929)
//   4. Connect request to the test target
//   5. Reply validation (REP code 0x00 == success)
//
// All networking is asynchronous and never blocks the main thread.

public struct SOCKS5Client: Sendable {
    public let proxyHost: String
    public let proxyPort: UInt16
    public let username: String?
    public let password: String?
    /// Host that the proxy will be asked to connect to during a test.
    public let targetHost: String
    public let targetPort: UInt16
    /// Overall timeout for the handshake in seconds.
    public let timeout: TimeInterval

    public init(
        proxyHost: String,
        proxyPort: UInt16,
        username: String? = nil,
        password: String? = nil,
        targetHost: String = "www.example.com",
        targetPort: UInt16 = 80,
        timeout: TimeInterval = 10
    ) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.username = username
        self.password = password
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.timeout = timeout
    }

    public init(
        configuration: ProxyConfiguration,
        targetHost: String = "www.example.com",
        targetPort: UInt16 = 80,
        timeout: TimeInterval = 10
    ) {
        let username = configuration.requiresAuthentication ? configuration.username : nil
        let password = configuration.requiresAuthentication ? configuration.password : nil
        self.init(
            proxyHost: configuration.host,
            proxyPort: UInt16(clamping: configuration.port),
            username: username,
            password: password,
            targetHost: targetHost,
            targetPort: targetPort,
            timeout: timeout
        )
    }

    /// Performs a full SOCKS5 handshake through the proxy and returns the
    /// elapsed time in seconds. Throws `ProxyTestFailure` on any failure.
    public func performConnectTest() async throws -> TimeInterval {
        let configuration = ProxyConfiguration(
            name: "SOCKS5 Client",
            type: .socks5,
            host: proxyHost,
            port: Int(proxyPort),
            authenticationEnabled: username != nil && password != nil,
            username: username ?? "",
            password: password
        )
        let tunnel = try await ProxyTunnel.open(
            configuration,
            targetHost: targetHost,
            targetPort: targetPort,
            timeout: timeout
        )
        tunnel.stream.close()
        return TimeInterval(tunnel.handshake.tcpMs + tunnel.handshake.handshakeMs) / 1000
    }

    /// Maps a low-level Network.framework error to a user-friendly failure.
    public static func failure(forNetworkError error: NWError) -> ProxyTestFailure {
        ProxyNetworkErrorMapper.map(error)
    }
}