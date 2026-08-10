import Foundation
import Network

// MARK: - SOCKS5Client
//
// A real SOCKS5 (RFC 1928 / RFC 1929) client built on the public Network
// framework. It performs the actual SOCKS5 handshake:
//
//   1. TCP connect to the proxy server
//   2. Greeting:  0x05, NMETHODS, METHODS...
//   3. (optional) Username/Password authentication (RFC 1929)
//   4. Connect request to the test target
//   5. Reply validation (REP code 0x00 == success)
//
// The public entry point `performConnectTest()` measures the elapsed time of
// the full handshake and returns it. All networking is asynchronous and never
// blocks the main thread.

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
        let start = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Timeout watchdog.
                let timeoutNanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ProxyTestFailure.timedOut
            }
            group.addTask {
                try await self.runHandshake()
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }

        return Date().timeIntervalSince(start)
    }

    // MARK: - Handshake

    private func runHandshake() async throws {
        let stream = try await SOCKS5Stream(host: proxyHost, port: proxyPort)
        // If the surrounding task is cancelled (user action or timeout
        // watchdog), close the socket so every pending await unblocks.
        try await withTaskCancellationHandler {
            try await Self.performHandshake(on: stream, client: self)
        } onCancel: {
            stream.close()
        }
    }

    private static func performHandshake(on stream: SOCKS5Stream, client: SOCKS5Client) async throws {
        // ── Step 1: Greeting ────────────────────────────────────────────
        let requiresAuth = client.username != nil && client.password != nil
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
            break // no authentication

        case 0x02:
            try await Self.performAuthentication(on: stream, client: client)

        case 0xFF:
            throw ProxyTestFailure.authenticationFailed

        default:
            throw ProxyTestFailure.protocolError
        }

        // ── Step 2: Connect request ─────────────────────────────────────
        var request = Data([0x05, 0x01, 0x00])
        request.append(client.encodeAddress(client.targetHost))
        request.append(UInt16(client.targetPort).bigEndianBytes)
        try await stream.send(request)

        let reply = try await stream.receiveExactly(4)
        guard reply.count == 4, reply[0] == 0x05 else {
            throw ProxyTestFailure.protocolError
        }
        let rep = reply[1]
        guard rep == 0x00 else {
            throw Self.failure(forReplyCode: rep)
        }

        // Consume the bound address so the handshake is fully complete.
        let atyp = reply[3]
        let boundAddressLength: Int
        switch atyp {
        case 0x01: boundAddressLength = 4      // IPv4
        case 0x04: boundAddressLength = 16     // IPv6
        case 0x03:                             // Domain name
            let lengthByte = try await stream.receiveExactly(1)
            guard lengthByte.count == 1 else { throw ProxyTestFailure.protocolError }
            boundAddressLength = Int(lengthByte[0])
        default:
            throw ProxyTestFailure.protocolError
        }
        _ = try await stream.receiveExactly(boundAddressLength)
        _ = try await stream.receiveExactly(2)
    }

    private static func performAuthentication(on stream: SOCKS5Stream, client: SOCKS5Client) async throws {
        guard let username = client.username, let password = client.password else {
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

    // MARK: - Encoding

    /// Encodes a destination host as a SOCKS5 ATYP + address payload.
    private func encodeAddress(_ host: String) -> Data {
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

    private static func failure(forReplyCode rep: UInt8) -> ProxyTestFailure {
        switch rep {
        case 0x01: return .generalFailure
        case 0x02: return .connectionFailed       // connection not allowed by ruleset
        case 0x03: return .networkUnreachable
        case 0x04: return .hostUnreachable
        case 0x05: return .connectionRefused
        case 0x06: return .generalFailure         // TTL expired
        case 0x07: return .protocolError          // command not supported
        case 0x08: return .protocolError          // address type not supported
        default:   return .generalFailure
        }
    }

    /// Maps a low-level Network.framework error to a user-friendly failure.
    public static func failure(forNetworkError error: NWError) -> ProxyTestFailure {
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
            default:            return .connectionFailed
            }
        case .dns:
            return .connectionFailed
        case .tls:
            return .connectionFailed
        @unknown default:
            return .connectionFailed
        }
    }
}

// MARK: - SOCKS5Stream
//
// Thin async wrapper around a TCP `NWConnection`.

private final class SOCKS5Stream {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.rakib.FluxDL.socks5")

    init(host: String, port: UInt16) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyTestFailure.invalidConfiguration("Invalid proxy port")
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: endpointPort
        )
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        try await withTaskCancellationHandler {
            try await Self.waitUntilReady(connection, on: queue)
        } onCancel: {
            connection.cancel()
        }
    }

    private static func waitUntilReady(_ connection: NWConnection, on queue: DispatchQueue) async throws {
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
                    continuation.resume(throwing: SOCKS5Client.failure(forNetworkError: error))
                case .cancelled:
                    // Cancelled by our own cancellation handler.
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break // .preparing / .waiting — timeout is handled externally
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: SOCKS5Client.failure(forNetworkError: error))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } catch {
            // Convert a cancellation-induced socket error into CancellationError.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveChunk(maximumLength: count - buffer.count)
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveChunk(maximumLength: Int) async throws -> Data {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: SOCKS5Client.failure(forNetworkError: error))
                    } else if let data = data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: ProxyTestFailure.connectionFailed)
                    }
                }
            }
        } catch {
            // Convert a cancellation-induced socket error into CancellationError.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func close() {
        connection.cancel()
    }
}

// MARK: - Helpers

private extension UInt16 {
    var bigEndianBytes: Data {
        Data([UInt8(self >> 8), UInt8(self & 0xFF)])
    }
}
