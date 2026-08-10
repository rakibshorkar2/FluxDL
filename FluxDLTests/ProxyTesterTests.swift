import XCTest
import Network
import Darwin
@testable import FluxDL

// MARK: - ClosedPortReserver
//
// Binds a local TCP socket (without listening) and keeps it open so the port
// is guaranteed to refuse connections while the test runs. Deterministic
// "connection refused" without racing other processes.

final class ClosedPortReserver {
    let port: UInt16
    private let socketFD: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw NSError(domain: "ClosedPortReserver", code: 1) }
        socketFD = fd

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "ClosedPortReserver", code: 2)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
    }

    deinit {
        Darwin.close(socketFD)
    }
}

// MARK: - MockSOCKSServer
//
// A real SOCKS5 server implementation used ONLY by tests. It listens on
// localhost and performs the server side of the handshake so the client code
// is exercised end-to-end (no fakes inside the production client).

final class MockSOCKSServer {
    enum Behavior {
        /// Completes the handshake and replies REP 0x00 (success).
        case accept
        /// Requires username/password auth with the given credentials.
        case requireAuth(username: String, password: String)
        /// Accepts the TCP connection but never responds (timeout test).
        case silent
        /// Replies REP 0x05 (connection refused) to the connect request.
        case refuse
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.mock.socks5")
    private let behavior: Behavior
    private var connections: [NWConnection] = []

    init(behavior: Behavior) throws {
        self.behavior = behavior
        listener = try NWListener(using: .tcp)
        port = listener.port?.rawValue ?? 0
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener.cancel()
    }

    // MARK: - Server state machine

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        switch behavior {
        case .silent:
            break // never read or write
        default:
            readGreeting(connection)
        }
    }

    private func readGreeting(_ connection: NWConnection) {
        receiveExactly(connection, 2) { [weak self] data in
            guard let data = data else { return }
            let methodCount = Int(data[1])
            self?.receiveExactly(connection, methodCount) { _ in
                guard let self = self else { return }
                switch self.behavior {
                case .accept:
                    self.send(connection, Data([0x05, 0x00]))
                    self.readConnectRequest(connection)
                case .requireAuth:
                    self.send(connection, Data([0x05, 0x02]))
                    self.readAuthRequest(connection)
                case .refuse:
                    self.send(connection, Data([0x05, 0x00]))
                    self.readConnectRequest(connection)
                case .silent:
                    break
                }
            }
        }
    }

    private func readAuthRequest(_ connection: NWConnection) {
        receiveExactly(connection, 2) { [weak self] data in
            guard let data = data else { return }
            let usernameLength = Int(data[1])
            self?.receiveExactly(connection, usernameLength) { usernameData in
                guard let usernameData = usernameData else { return }
                self?.receiveExactly(connection, 1) { lengthData in
                    guard let lengthData = lengthData else { return }
                    let passwordLength = Int(lengthData[0])
                    self?.receiveExactly(connection, passwordLength) { passwordData in
                        guard let self = self, let passwordData = passwordData else { return }
                        let username = String(data: usernameData, encoding: .utf8) ?? ""
                        let password = String(data: passwordData, encoding: .utf8) ?? ""
                        if case .requireAuth(let expectedUser, let expectedPass) = self.behavior,
                           username == expectedUser, password == expectedPass {
                            self.send(connection, Data([0x01, 0x00]))
                            self.readConnectRequest(connection)
                        } else {
                            self.send(connection, Data([0x01, 0x01]))
                            connection.cancel()
                        }
                    }
                }
            }
        }
    }

    private func readConnectRequest(_ connection: NWConnection) {
        receiveExactly(connection, 4) { [weak self] data in
            guard let data = data else { return }
            let atyp = data[3]
            switch atyp {
            case 0x01: self?.receiveExactly(connection, 4) { _ in self?.finishConnect(connection) }
            case 0x04: self?.receiveExactly(connection, 16) { _ in self?.finishConnect(connection) }
            case 0x03:
                self?.receiveExactly(connection, 1) { lengthData in
                    guard let lengthData = lengthData else { return }
                    self?.receiveExactly(connection, Int(lengthData[0])) { _ in self?.finishConnect(connection) }
                }
            default:
                self?.send(connection, Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            }
        }
    }

    private func finishConnect(_ connection: NWConnection) {
        receiveExactly(connection, 2) { [weak self] _ in
            guard let self = self else { return }
            switch self.behavior {
            case .refuse:
                self.send(connection, Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            default:
                self.send(connection, Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 80]))
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveExactly(_ connection: NWConnection, _ count: Int, completion: @escaping (Data?) -> Void) {
        receiveExactlyInternal(connection, remaining: count, accumulated: Data(), completion: completion)
    }

    private func receiveExactlyInternal(
        _ connection: NWConnection,
        remaining: Int,
        accumulated: Data,
        completion: @escaping (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data, _, _, _ in
            guard let data = data, !data.isEmpty else {
                completion(nil)
                return
            }
            var accumulated = accumulated
            accumulated.append(data)
            if accumulated.count < remaining {
                self.receiveExactlyInternal(connection, remaining: remaining, accumulated: accumulated, completion: completion)
            } else {
                completion(accumulated)
            }
        }
    }
}

// MARK: - ProxyTesterTests

@MainActor
final class ProxyTesterTests: XCTestCase {

    private func configuration(host: String, port: Int, username: String? = nil, password: String? = nil) -> ProxyConfiguration {
        let authEnabled = username != nil && password != nil
        return ProxyConfiguration(
            name: "Mock",
            type: .socks5,
            host: host,
            port: port,
            authenticationEnabled: authEnabled,
            username: username ?? "",
            password: password
        )
    }

    private func service() -> ProxyService {
        let suiteName = "ProxyTesterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ProxyService(
            keychainStore: MockKeychainStore(),
            defaults: defaults
        )
    }

    func testSuccessfulConnectionMeasuresLatency() async throws {
        let server = try MockSOCKSServer(behavior: .accept)
        defer { server.stop() }

        let service = service()
        let result = try await service.test(configuration(host: "127.0.0.1", port: Int(server.port)))

        XCTAssertTrue(result.success, "Expected success but got: \(result.failure?.userMessage ?? "nil")")
        XCTAssertNotNil(result.latencyMs)
        XCTAssertGreaterThan(result.latencyMs ?? 0, 0)
        XCTAssertNil(result.failure)
    }

    func testAuthenticationSuccess() async throws {
        let server = try MockSOCKSServer(behavior: .requireAuth(username: "user", password: "pass"))
        defer { server.stop() }

        let service = service()
        let result = try await service.test(
            configuration(host: "127.0.0.1", port: Int(server.port), username: "user", password: "pass")
        )

        XCTAssertTrue(result.success, "Expected success but got: \(result.failure?.userMessage ?? "nil")")
    }

    func testAuthenticationFailure() async throws {
        let server = try MockSOCKSServer(behavior: .requireAuth(username: "user", password: "pass"))
        defer { server.stop() }

        let service = service()
        let result = try await service.test(
            configuration(host: "127.0.0.1", port: Int(server.port), username: "user", password: "WRONG")
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure, .authenticationFailed)
    }

    func testTimeoutWhenServerDoesNotRespond() async throws {
        let server = try MockSOCKSServer(behavior: .silent)
        defer { server.stop() }

        let service = service()
        service.testTimeout = 1
        let result = try await service.test(configuration(host: "127.0.0.1", port: Int(server.port)))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure, .timedOut)
    }

    func testConnectionRefused() async throws {
        let reserver = try ClosedPortReserver()

        let service = service()
        service.testTimeout = 2
        let result = try await service.test(configuration(host: "127.0.0.1", port: Int(reserver.port)))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure, .connectionRefused)
    }

    func testProxyRefusesTargetConnection() async throws {
        let server = try MockSOCKSServer(behavior: .refuse)
        defer { server.stop() }

        let service = service()
        let result = try await service.test(configuration(host: "127.0.0.1", port: Int(server.port)))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure, .connectionRefused)
    }

    func testInvalidConfigurationNeverHitsNetwork() async throws {
        let service = service()
        let result = try await service.test(
            ProxyConfiguration(name: "Bad", host: "not valid!", port: 70000)
        )
        XCTAssertFalse(result.success)
        guard case .some(.invalidConfiguration) = result.failure else {
            XCTFail("Expected invalidConfiguration failure, got \(String(describing: result.failure))")
            return
        }
    }

    func testCancellationIsPrompt() async throws {
        let server = try MockSOCKSServer(behavior: .silent)
        defer { server.stop() }

        let service = service()
        service.testTimeout = 30

        let task = Task { () -> ProxyTestResult in
            do {
                return try await service.test(configuration(host: "127.0.0.1", port: Int(server.port)))
            } catch {
                return .failure(.connectionFailed)
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        let result = await task.value
        XCTAssertFalse(result.success, "Cancelled test must not report success.")
    }
}
