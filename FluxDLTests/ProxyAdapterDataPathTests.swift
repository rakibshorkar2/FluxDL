import XCTest
import Network
@testable import FluxDL

// MARK: - MockHTTPProxyServer
//
// A minimal HTTP proxy used ONLY by tests: answers absolute-form forward
// requests and CONNECT tunnels, optionally requiring Proxy-Authorization,
// and serves a canned HTTP 200 response for the tunneled request.

final class MockHTTPProxyServer {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.mock.http.proxy")
    private let credentials: (username: String, password: String)?
    private var connections: [NWConnection] = []
    private(set) var connectionCount = 0
    private(set) var lastRequestLine: String?

    init(requireAuth: (String, String)? = nil) throws {
        self.credentials = requireAuth
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

    private func handle(_ connection: NWConnection) {
        connectionCount += 1
        connections.append(connection)
        connection.start(queue: queue)
        readHead(connection)
    }

    private func readHead(_ connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { return }
            var accumulated = accumulated
            accumulated.append(data)
            let separator = Data("\r\n\r\n".utf8)
            guard let range = accumulated.range(of: separator) else {
                self.readHead(connection, accumulated: accumulated)
                return
            }
            let head = String(data: accumulated[..<range.lowerBound], encoding: .utf8) ?? ""
            let lines = head.components(separatedBy: "\r\n")
            self.lastRequestLine = lines.first
            guard let firstLine = lines.first, !firstLine.isEmpty else { return }

            if let creds = self.credentials {
                let expected = "Basic "
                    + "\(creds.username):\(creds.password)".data(using: .utf8)!.base64EncodedString()
                guard lines.contains(where: { $0 == "Proxy-Authorization: \(expected)" }) else {
                    connection.send(
                        content: Data("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in }
                    )
                    return
                }
            }

            if firstLine.hasPrefix("CONNECT ") {
                connection.send(
                    content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                            guard let data, !data.isEmpty else { return }
                            connection.send(
                                content: Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nHello mock\n".utf8),
                                completion: .contentProcessed { _ in }
                            )
                        }
                    }
                )
            } else {
                connection.send(
                    content: Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nHello mock\n".utf8),
                    completion: .contentProcessed { _ in }
                )
            }
        }
    }
}

// MARK: - MockSOCKS4Server
//
// A minimal SOCKS4/4a server used ONLY by tests: completes the SOCKS4
// handshake (IPv4 destinations), then answers the tunneled request with a
// canned HTTP 200 response.

final class MockSOCKS4Server {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.mock.socks4")
    private var connections: [NWConnection] = []
    private(set) var connectionCount = 0

    init() throws {
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

    private func handle(_ connection: NWConnection) {
        connectionCount += 1
        connections.append(connection)
        connection.start(queue: queue)
        receiveExactly(connection, 8) { [weak self] data in
            guard let data, data.count == 8, data[0] == 0x04, data[1] == 0x01 else { return }
            // Null-terminated user ID (and host for SOCKS4a).
            self?.readUntilNull(connection) {
                self?.finish(connection)
            }
        }
    }

    private func readUntilNull(_ connection: NWConnection, completion: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, _, _ in
            guard let data, !data.isEmpty else {
                completion()
                return
            }
            if data.contains(0) {
                completion()
            } else {
                self?.readUntilNull(connection, completion: completion)
            }
        }
    }

    private func finish(_ connection: NWConnection) {
        // REP success: [0x00, 0x5A, port, port, IPv4].
        connection.send(content: Data([0x00, 0x5A, 0x00, 0x00, 127, 0, 0, 1]), completion: .contentProcessed { _ in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                guard let data, !data.isEmpty else { return }
                connection.send(
                    content: Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nHello mock\n".utf8),
                    completion: .contentProcessed { _ in }
                )
            }
        })
    }

    private func receiveExactly(_ connection: NWConnection, _ count: Int, completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            guard let data, data.count == count else {
                completion(nil)
                return
            }
            completion(data)
        }
    }
}

// MARK: - ProxyAdapterDataPathTests
//
// Exercises the REAL data path used by Downloads and Browser: a URLSession
// configured through `ProxySessionProvider` fetching through the local
// adapter against live upstream proxy servers. This is where the old
// implementation failed — authenticated SOCKS5 was handed to the adapter,
// which could only speak SOCKS4 upstream.

@MainActor
final class ProxyAdapterDataPathTests: XCTestCase {

    private func performGET(
        provider: ProxySessionProvider,
        configuration: ProxyConfiguration,
        url: URL,
        timeout: TimeInterval = 10
    ) async throws -> (Data, URLResponse) {
        let sessionConfig = provider.sessionConfiguration(for: configuration)
        sessionConfig.timeoutIntervalForRequest = 5
        sessionConfig.timeoutIntervalForResource = 10
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(from: url)
    }

    private func assertCannedResponse(_ data: Data, _ response: URLResponse) {
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "Hello mock\n")
    }

    // MARK: - SOCKS5 upstream (the previously broken data path)

    func testAuthSOCKS5RoutesThroughAdapterDataPath() async throws {
        let server = try MockSOCKSServer(behavior: .httpRespond(username: "user", password: "pass", delay: 0))
        defer { server.stop() }

        let provider = ProxySessionProvider()
        defer { provider.stopAdapter() }
        let configuration = ProxyConfiguration(
            name: "Auth SOCKS5",
            type: .socks5,
            host: "127.0.0.1",
            port: Int(server.port),
            authenticationEnabled: true,
            username: "user",
            password: "pass"
        )

        XCTAssertNil(provider.prepare(configuration), "The adapter must bind for authenticated SOCKS5.")
        let (data, response) = try await performGET(
            provider: provider,
            configuration: configuration,
            url: URL(string: "http://127.0.0.1:\(server.port)/file.bin")!
        )

        assertCannedResponse(data, response)
        XCTAssertEqual(server.connectionCount, 1, "Traffic must traverse the authenticated SOCKS5 server.")
    }

    func testAuthSOCKS5WrongPasswordFailsClosed() async throws {
        let server = try MockSOCKSServer(behavior: .httpRespond(username: "user", password: "pass", delay: 0))
        defer { server.stop() }

        let provider = ProxySessionProvider()
        defer { provider.stopAdapter() }
        let configuration = ProxyConfiguration(
            name: "Bad Auth",
            type: .socks5,
            host: "127.0.0.1",
            port: Int(server.port),
            authenticationEnabled: true,
            username: "user",
            password: "wrong"
        )

        XCTAssertNil(provider.prepare(configuration))
        do {
            _ = try await performGET(
                provider: provider,
                configuration: configuration,
                url: URL(string: "http://127.0.0.1:\(server.port)/file.bin")!
            )
            XCTFail("A request through a rejected proxy must fail, not succeed direct.")
        } catch {
            // Expected: RFC 1929 rejection ends the connection.
        }
    }

    func testSOCKS4RoutesThroughAdapterDataPath() async throws {
        let server = try MockSOCKS4Server()
        defer { server.stop() }

        let provider = ProxySessionProvider()
        defer { provider.stopAdapter() }
        let configuration = ProxyConfiguration(
            name: "SOCKS4",
            type: .socks4,
            host: "127.0.0.1",
            port: Int(server.port)
        )

        XCTAssertNil(provider.prepare(configuration), "The adapter must bind for SOCKS4.")
        let (data, response) = try await performGET(
            provider: provider,
            configuration: configuration,
            url: URL(string: "http://127.0.0.1:\(server.port)/file.bin")!
        )

        assertCannedResponse(data, response)
        XCTAssertEqual(server.connectionCount, 1, "Traffic must traverse the SOCKS4 server.")
    }

    // MARK: - HTTP CONNECT upstream (authenticated)

    func testAuthHTTPConnectRoutesThroughAdapterDataPath() async throws {
        let server = try MockHTTPProxyServer(requireAuth: ("user", "pass"))
        defer { server.stop() }

        let provider = ProxySessionProvider()
        defer { provider.stopAdapter() }
        let configuration = ProxyConfiguration(
            name: "Auth HTTP",
            type: .http,
            host: "127.0.0.1",
            port: Int(server.port),
            authenticationEnabled: true,
            username: "user",
            password: "pass"
        )

        XCTAssertNil(provider.prepare(configuration), "The adapter must bind for authenticated HTTP.")
        let (data, response) = try await performGET(
            provider: provider,
            configuration: configuration,
            url: URL(string: "http://127.0.0.1:\(server.port)/file.bin")!
        )

        assertCannedResponse(data, response)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testAuthHTTPConnectWrongPasswordFailsClosed() async throws {
        let server = try MockHTTPProxyServer(requireAuth: ("user", "pass"))
        defer { server.stop() }

        let provider = ProxySessionProvider()
        defer { provider.stopAdapter() }
        let configuration = ProxyConfiguration(
            name: "Bad HTTP Auth",
            type: .http,
            host: "127.0.0.1",
            port: Int(server.port),
            authenticationEnabled: true,
            username: "user",
            password: "wrong"
        )

        XCTAssertNil(provider.prepare(configuration))
        do {
            _ = try await performGET(
                provider: provider,
                configuration: configuration,
                url: URL(string: "http://127.0.0.1:\(server.port)/file.bin")!
            )
            XCTFail("A request through a 407 proxy must fail, not succeed direct.")
        } catch {
            // Expected.
        }
    }

    // MARK: - Native paths (no adapter)

    func testSOCKS5NoAuthNativeDataPath() async throws {
        let server = try MockSOCKSServer(behavior: .httpRespond(username: nil, password: nil, delay: 0))
        defer { server.stop() }

        let provider = ProxySessionProvider()
        defer { provider.stopAdapter() }
        let configuration = ProxyConfiguration(
            name: "SOCKS5",
            type: .socks5,
            host: "127.0.0.1",
            port: Int(server.port)
        )

        XCTAssertNil(provider.prepare(configuration))
        let (data, response) = try await performGET(
            provider: provider,
            configuration: configuration,
            url: URL(string: "http://127.0.0.1:\(server.port)/file.bin")!
        )

        assertCannedResponse(data, response)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testHTTPNoAuthNativeDataPath() async throws {
        let server = try MockHTTPProxyServer()
        defer { server.stop() }

        let provider = ProxySessionProvider()
        defer { provider.stopAdapter() }
        let configuration = ProxyConfiguration(
            name: "HTTP",
            type: .http,
            host: "127.0.0.1",
            port: Int(server.port)
        )

        XCTAssertNil(provider.prepare(configuration))
        let (data, response) = try await performGET(
            provider: provider,
            configuration: configuration,
            url: URL(string: "http://127.0.0.1:\(server.port)/file.bin")!
        )

        assertCannedResponse(data, response)
        XCTAssertEqual(server.connectionCount, 1)
    }
}

// MARK: - MockProxyProvider

@MainActor
private final class MockProxyProvider: ProxyProviding {
    var isEnabled = false
    var activeConfiguration: ProxyConfiguration?
    var connectionState: ProxyConnectionState = .disabled
    var browserProxyEnabled = false
    var downloadsProxyEnabled = false

    func enable() async {}
    func disable() {}
    func activate(_ proxy: ProxyProfile) async throws {}
    func deactivate() {}
    func test(_ configuration: ProxyConfiguration) async throws -> ProxyTestResult {
        .success(latencyMs: 1)
    }
}

// MARK: - ProxyRoutingIntegrationTests
//
// DownloadEngine-level routing: in-flight downloads on a dropped proxied
// session must be requeued (never silently continue through the old proxy
// configuration) and restarted on the current route.

@MainActor
final class ProxyRoutingIntegrationTests: XCTestCase {

    func testProfileSwitchRequeuesInFlightDownloads() async throws {
        let serverA = try MockSOCKSServer(behavior: .httpRespond(username: nil, password: nil, delay: 2))
        defer { serverA.stop() }
        let serverB = try MockSOCKSServer(behavior: .httpRespond(username: nil, password: nil, delay: 0))
        defer { serverB.stop() }

        let configA = ProxyConfiguration(name: "A", type: .socks5, host: "127.0.0.1", port: Int(serverA.port))
        let configB = ProxyConfiguration(name: "B", type: .socks5, host: "127.0.0.1", port: Int(serverB.port))

        let provider = MockProxyProvider()
        provider.isEnabled = true
        provider.downloadsProxyEnabled = true
        provider.connectionState = .connected
        provider.activeConfiguration = configA

        let engine = DownloadEngine(
            repository: DownloadRepository(),
            fileManagerService: FileManagementService(),
            hapticService: ServiceContainer.shared.hapticService,
            notificationService: ServiceContainer.shared.notificationService
        )
        engine.proxyProvider = provider
        defer { engine.session.invalidateAndCancel() }

        let id = engine.startDownload(
            url: URL(string: "http://127.0.0.1:\(serverA.port)/file.bin")!
        )

        // Wait until the request is genuinely IN FLIGHT through proxy A
        // (the SOCKS5 tunnel is established and the GET was received), so
        // the switch below always interrupts a live download.
        await waitUntil { serverA.servedHTTPResponses == 1 }

        // Switch profiles while the download is in-flight on proxy A. The
        // dropped session's tasks are requeued and restarted on the new
        // route — if the old behavior (finishTasksAndInvalidate) were still
        // in place, the download would complete through proxy A instead.
        provider.activeConfiguration = configB
        engine.refreshProxyRouting()

        // The task completes through the NEW proxy — proxy A never delivers
        // the content (its response is delayed 2s and its tunnel is torn
        // down by the requeue; a stale-route download would have finished
        // there instead).
        await waitUntil { engine.tasks.first(where: { $0.id == id })?.status == .completed }
        XCTAssertEqual(serverB.connectionCount, 1, "The download must complete through the NEW proxy.")
        XCTAssertEqual(serverB.servedHTTPResponses, 1)
        XCTAssertEqual(serverA.servedHTTPResponses, 1, "A received the initial request — it was truly in-flight.")
        XCTAssertEqual(serverA.deliveredHTTPResponses, 0, "The stale proxy must never deliver the download.")
        XCTAssertEqual(serverA.connectionCount, 1)
    }

    func testDisableDuringInFlightDownloadDoesNotContinueThroughProxy() async throws {
        let serverA = try MockSOCKSServer(behavior: .httpRespond(username: nil, password: nil, delay: 2))
        defer { serverA.stop() }

        let configA = ProxyConfiguration(name: "A", type: .socks5, host: "127.0.0.1", port: Int(serverA.port))

        let provider = MockProxyProvider()
        provider.isEnabled = true
        provider.downloadsProxyEnabled = true
        provider.connectionState = .connected
        provider.activeConfiguration = configA

        let engine = DownloadEngine(
            repository: DownloadRepository(),
            fileManagerService: FileManagementService(),
            hapticService: ServiceContainer.shared.hapticService,
            notificationService: ServiceContainer.shared.notificationService
        )
        engine.proxyProvider = provider
        defer { engine.session.invalidateAndCancel() }

        let id = engine.startDownload(
            url: URL(string: "http://127.0.0.1:\(serverA.port)/file.bin")!
        )

        // Wait until the request is genuinely in-flight through proxy A.
        await waitUntil { serverA.servedHTTPResponses == 1 }

        // The user disables the proxy while the download is in flight.
        provider.isEnabled = false
        provider.connectionState = .disabled
        provider.activeConfiguration = nil
        engine.refreshProxyRouting()

        // Under the old behavior the in-flight task would have completed
        // through the disabled proxy at ~2s. Now it is requeued and restarted
        // direct (explicit disable = the user's intent to go direct) — and
        // the disabled proxy must never deliver the download.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let task = engine.tasks.first(where: { $0.id == id })
        XCTAssertNotEqual(task?.status, .completed, "A disabled proxy must never deliver the download.")
        XCTAssertEqual(serverA.servedHTTPResponses, 1, "A received the initial request — it was truly in-flight.")
        XCTAssertEqual(serverA.deliveredHTTPResponses, 0, "The disabled proxy must never deliver content.")

        engine.cancelDownload(id: id)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}