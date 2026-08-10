import Foundation
import Network

// MARK: - ProxyStream
//
// Async wrapper around a TCP (optionally TLS) `NWConnection`. All I/O is
// cancellation-aware: cancelling the surrounding task closes the socket so
// every pending await unblocks.

public final class ProxyStream: Sendable {

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.rakib.FluxDL.proxy.stream")

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Connects to `host:port` (optionally TLS) and waits until `.ready`.
    /// Throws `ProxyTestFailure` on connection failure or timeout handled
    /// upstream by the caller's watchdog.
    public static func connect(host: String, port: UInt16, isTLS: Bool = false) async throws -> ProxyStream {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyTestFailure.invalidConfiguration("Invalid proxy port")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        let parameters: NWParameters = isTLS ? .tls : .tcp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(to: endpoint, using: parameters)
        let stream = ProxyStream(connection: connection)

        try await withTaskCancellationHandler {
            try await stream.waitUntilReady()
        } onCancel: {
            connection.cancel()
        }
        return stream
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: ProxyNetworkErrorMapper.map(error))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break // .preparing / .waiting — timeout handled by watchdog
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Sends a full data payload (content-processed semantics).
    public func send(_ data: Data) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: ProxyNetworkErrorMapper.map(error))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Receives exactly `count` bytes.
    public func receiveExactly(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveChunk(maximumLength: count - buffer.count)
            buffer.append(chunk)
        }
        return buffer
    }

    /// Receives until `\r\n\r\n` (HTTP header terminator) with a size cap.
    public func receiveUntilHeaderEnd(maximumBytes: Int = 65_536) async throws -> Data {
        var buffer = Data()
        while buffer.count < maximumBytes {
            let chunk = try await receiveChunk(maximumLength: 4_096)
            buffer.append(chunk)
            if buffer.range(of: headerTerminator, options: [.backwards], in: buffer.startIndex..<buffer.endIndex) != nil {
                return buffer
            }
        }
        throw ProxyTestFailure.protocolError
    }

    private var headerTerminator: Data { Data("\r\n\r\n".utf8) }

    private func receiveChunk(maximumLength: Int) async throws -> Data {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: ProxyNetworkErrorMapper.map(error))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: ProxyTestFailure.connectionFailed)
                    } else {
                        continuation.resume(throwing: ProxyTestFailure.connectionFailed)
                    }
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    public func close() {
        connection.cancel()
    }
}

// MARK: - ProxyNetworkErrorMapper

public enum ProxyNetworkErrorMapper {
    public static func map(_ error: NWError) -> ProxyTestFailure {
        switch error {
        case .posix(let posixError):
            switch posixError {
            case .ECONNREFUSED: return .connectionRefused
            case .ENETUNREACH:  return .networkUnreachable
            case .EHOSTUNREACH: return .hostUnreachable
            case .ETIMEDOUT:    return .timedOut
            case .ENETDOWN:     return .networkUnavailable
            case .ENOTCONN, .EPIPE, .ECONNRESET, .ECONNABORTED:
                return .connectionFailed
            case .EAFNOSUPPORT:
                return .proxyUnavailable
            default:            return .connectionFailed
            }
        case .dns:
            return .dnsFailure
        case .tls:
            return .tlsHandshakeFailed
        @unknown default:
            return .connectionFailed
        }
    }
}

// MARK: - ProxyTunnelHandshake

/// Per-phase timings of a successful proxy tunnel setup.
public struct ProxyTunnelHandshake: Sendable {
    public let tcpMs: Int
    public let handshakeMs: Int

    public init(tcpMs: Int, handshakeMs: Int) {
        self.tcpMs = tcpMs
        self.handshakeMs = handshakeMs
    }
}

// MARK: - ProxyTunnel
//
// Opens a tunneled connection to `targetHost:targetPort` through any of the
// four supported proxy protocols and returns the open stream plus per-phase
// timing. This is the single path used by the tester, the SOCKS4 adapter and
// any future transport needing raw tunneled connections.

public enum ProxyTunnel {

    public struct Tunnel: Sendable {
        public let handshake: ProxyTunnelHandshake
        public let stream: ProxyStream
    }

    /// Whether the tunnel should ask the proxy to resolve the destination
    /// hostname remotely (SOCKS5 domain form / SOCKS4a).
    public static let useRemoteDNS = true

    /// Opens a tunnel through `configuration`. Measures TCP connect time and
    /// protocol handshake time separately. `tlsToProxy` enables TLS for
    /// HTTPS proxies (`configuration.type == .https` is handled internally).
    public static func open(
        _ configuration: ProxyConfiguration,
        targetHost: String,
        targetPort: UInt16,
        timeout: TimeInterval,
        tlsToProxy: Bool? = nil
    ) async throws -> Tunnel {
        let useTLS = tlsToProxy ?? (configuration.type == .https)
        let tcpStart = Date()
        let stream = try await withTimeout(timeout) { () async throws -> ProxyStream in
            try await ProxyStream.connect(host: configuration.host, port: UInt16(clamping: configuration.port), isTLS: useTLS)
        }
        let tcpMs = max(1, Int((Date().timeIntervalSince(tcpStart) * 1000).rounded()))

        let handshakeStart = Date()
        try await withTimeout(timeout) {
            try await performHandshake(in: configuration, targetHost: targetHost, targetPort: targetPort, on: stream)
        }
        let handshakeMs = max(1, Int((Date().timeIntervalSince(handshakeStart) * 1000).rounded()))

        return Tunnel(handshake: ProxyTunnelHandshake(tcpMs: tcpMs, handshakeMs: handshakeMs), stream: stream)
    }

    // MARK: - Handshake dispatch

    public static func performHandshake(
        in configuration: ProxyConfiguration,
        targetHost: String,
        targetPort: UInt16,
        on stream: ProxyStream
    ) async throws {
        switch configuration.type {
        case .socks5:
            let username = configuration.requiresAuthentication ? configuration.username : nil
            let password = configuration.requiresAuthentication ? configuration.password : nil
            try await SOCKSHandshake.perform(
                on: stream,
                username: username,
                password: password,
                targetHost: targetHost,
                targetPort: targetPort
            )
        case .socks4:
            try await SOCKSHandshake.performSocks4(
                on: stream,
                userID: configuration.username,
                targetHost: targetHost,
                targetPort: targetPort
            )
        case .http, .https:
            try await HTTPCONNECTHandshake.perform(
                on: stream,
                targetHost: targetHost,
                targetPort: targetPort,
                username: configuration.requiresAuthentication ? configuration.username : nil,
                password: configuration.requiresAuthentication ? configuration.password : nil
            )
        }
    }

    // MARK: - Timeout helper

    private static func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                let timeoutNanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ProxyTestFailure.timedOut
            }
            group.addTask {
                try await operation()
            }
            do {
                guard let value = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

// MARK: - SOCKSHandshake
//
// RFC 1928 (SOCKS5) and SOCKS4/4a handshake implementations.

public enum SOCKSHandshake {

    // ── SOCKS5 ──────────────────────────────────────────────────────────────

    public static func perform(
        on stream: ProxyStream,
        username: String?,
        password: String?,
        targetHost: String,
        targetPort: UInt16
    ) async throws {
        let requiresAuth = username != nil && password != nil
        let methods: [UInt8] = requiresAuth ? [0x00, 0x02] : [0x00]
        var greeting = Data([0x05, UInt8(methods.count)])
        greeting.append(contentsOf: methods)
        try await stream.send(greeting)

        let greetingReply = try await stream.receiveExactly(2)
        guard greetingReply.count == 2, greetingReply[0] == 0x05 else {
            throw ProxyTestFailure.protocolError
        }
        let method = greetingReply[1]

        switch method {
        case 0x00:
            break
        case 0x02:
            try await performAuthentication(on: stream, username: username, password: password)
        case 0xFF:
            throw ProxyTestFailure.authenticationFailed
        default:
            throw ProxyTestFailure.protocolError
        }

        var request = Data([0x05, 0x01, 0x00])
        request.append(encodeAddress(targetHost))
        request.append(UInt16(targetPort).bigEndianBytes)
        try await stream.send(request)

        let reply = try await stream.receiveExactly(4)
        guard reply.count == 4, reply[0] == 0x05 else {
            throw ProxyTestFailure.protocolError
        }
        let rep = reply[1]
        guard rep == 0x00 else {
            throw failure(forReplyCode: rep)
        }

        // Consume the bound address so the handshake is fully complete.
        let atyp = reply[3]
        let boundAddressLength: Int
        switch atyp {
        case 0x01: boundAddressLength = 4
        case 0x04: boundAddressLength = 16
        case 0x03:
            let lengthByte = try await stream.receiveExactly(1)
            guard lengthByte.count == 1 else { throw ProxyTestFailure.protocolError }
            boundAddressLength = Int(lengthByte[0])
        default:
            throw ProxyTestFailure.protocolError
        }
        _ = try await stream.receiveExactly(boundAddressLength)
        _ = try await stream.receiveExactly(2)
    }

    private static func performAuthentication(
        on stream: ProxyStream,
        username: String?,
        password: String?
    ) async throws {
        guard let username, let password else {
            throw ProxyTestFailure.authenticationFailed
        }
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        guard usernameBytes.count <= 255, passwordBytes.count <= 255 else {
            throw ProxyTestFailure.protocolError
        }

        var auth = Data([0x01, UInt8(usernameBytes.count)])
        auth.append(contentsOf: usernameBytes)
        auth.append(UInt8(passwordBytes.count))
        auth.append(contentsOf: passwordBytes)
        try await stream.send(auth)

        let authReply = try await stream.receiveExactly(2)
        guard authReply.count == 2, authReply[0] == 0x01 else {
            throw ProxyTestFailure.protocolError
        }
        guard authReply[1] == 0x00 else {
            throw ProxyTestFailure.authenticationFailed
        }
    }

    /// Encodes a destination host as SOCKS5 ATYP + address payload.
    private static func encodeAddress(_ host: String) -> Data {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            var data = Data([0x01])
            withUnsafeBytes(of: &ipv4) { data.append(contentsOf: $0) }
            return data
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            var data = Data([0x04])
            withUnsafeBytes(of: &ipv6) { data.append(contentsOf: $0) }
            return data
        }
        let bytes = Array(host.utf8)
        var data = Data([0x03, UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        return data
    }

    public static func failure(forReplyCode rep: UInt8) -> ProxyTestFailure {
        switch rep {
        case 0x01: return .generalFailure
        case 0x02: return .connectionFailed
        case 0x03: return .networkUnreachable
        case 0x04: return .hostUnreachable
        case 0x05: return .connectionRefused
        case 0x06: return .generalFailure
        case 0x07: return .protocolError
        case 0x08: return .protocolError
        default:   return .generalFailure
        }
    }

    // ── SOCKS4 / SOCKS4a ────────────────────────────────────────────────────

    /// SOCKS4 connect with automatic SOCKS4a fallback:
    ///   * IPv4 destination   → classic SOCKS4 binary address
    ///   * hostname destination → SOCKS4a (DSTIP = 0.0.0.1, hostname appended)
    /// IPv6 destinations are not expressible in SOCKS4 and fail cleanly.
    public static func performSocks4(
        on stream: ProxyStream,
        userID: String?,
        targetHost: String,
        targetPort: UInt16
    ) async throws {
        var ipv4 = in_addr()
        let isIPv4Literal = inet_pton(AF_INET, targetHost, &ipv4) == 1

        var request = Data([0x04, 0x01])
        request.append(UInt16(targetPort).bigEndianBytes)

        if isIPv4Literal {
            withUnsafeBytes(of: &ipv4) { request.append(contentsOf: $0) }
        } else {
            if ProxyConfigurationValidator.isIPv6(targetHost) {
                throw ProxyTestFailure.destinationConnectionFailed
            }
            // SOCKS4a: marker address signals a domain name follows.
            request.append(contentsOf: [0, 0, 0, 1])
        }

        let userIDBytes = Array((userID ?? "").utf8)
        request.append(contentsOf: userIDBytes)
        request.append(0)

        if !isIPv4Literal {
            let hostBytes = Array(targetHost.utf8)
            guard !hostBytes.isEmpty else { throw ProxyTestFailure.invalidConfiguration("Missing destination host") }
            request.append(contentsOf: hostBytes)
            request.append(0)
        }

        try await stream.send(request)

        let reply = try await stream.receiveExactly(8)
        guard reply.count == 8 else { throw ProxyTestFailure.protocolError }
        guard reply[0] == 0x00 else { throw ProxyTestFailure.protocolError }
        switch reply[1] {
        case 90: return // granted
        case 91: throw ProxyTestFailure.generalFailure       // request rejected/failed
        case 92: throw ProxyTestFailure.destinationConnectionFailed
        case 93: throw ProxyTestFailure.networkUnreachable
        default: throw ProxyTestFailure.generalFailure
        }
    }
}

// MARK: - HTTPCONNECTHandshake
//
// RFC 7231 CONNECT used by both plain HTTP and TLS (HTTPS) proxies.

public enum HTTPCONNECTHandshake {

    public static func perform(
        on stream: ProxyStream,
        targetHost: String,
        targetPort: UInt16,
        username: String?,
        password: String?
    ) async throws {
        let authority = "\(displayHost(targetHost)):\(targetPort)"
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Connection: keep-alive\r\n"
        if let username, let password {
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(credentials)\r\n"
        }
        request += "\r\n"
        try await stream.send(Data(request.utf8))

        let response = try await stream.receiveUntilHeaderEnd()
        guard let firstLine = String(data: response, encoding: .utf8)?
            .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first else {
            throw ProxyTestFailure.protocolError
        }
        let components = firstLine.split(separator: " ")
        guard components.count >= 2, components[0].hasPrefix("HTTP/") else {
            throw ProxyTestFailure.protocolError
        }
        guard let statusCode = Int(components[1]) else {
            throw ProxyTestFailure.protocolError
        }
        switch statusCode {
        case 200...299:
            return
        case 407:
            throw ProxyTestFailure.httpAuthenticationFailed
        case 403, 405:
            throw ProxyTestFailure.generalFailure
        default:
            throw ProxyTestFailure.generalFailure
        }
    }

    private static func displayHost(_ host: String) -> String {
        ProxyConfigurationValidator.bracketedHost(host)
    }
}

// MARK: - UInt16 helper

private extension UInt16 {
    var bigEndianBytes: Data {
        Data([UInt8(self >> 8), UInt8(self & 0xFF)])
    }
}