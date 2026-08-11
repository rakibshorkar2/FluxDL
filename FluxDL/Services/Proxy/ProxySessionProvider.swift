import Foundation
import Network
import Combine

// MARK: - ProxyNetworkConfigurationBuilder
//
// Converts a FluxDL `ProxyConfiguration` into Apple's modern
// `Network.ProxyConfiguration` (iOS 17+). Deprecated
// `connectionProxyDictionary` is NOT used as the primary path.
//
//   SOCKS5  → ProxyConfiguration(socksv5Proxy:) + applyCredential
//   HTTP    → ProxyConfiguration(httpCONNECTProxy:tlsOptions: nil)
//   HTTPS   → ProxyConfiguration(httpCONNECTProxy:tlsOptions: TLS options)
//   SOCKS4  → NOT natively supported by Network.framework — the caller must
//             use `LocalSOCKS5Adapter` (a local SOCKS5 endpoint bridging to
//             the upstream SOCKS4/4a server) instead. Returns nil.

public enum ProxyNetworkConfigurationBuilder {

    /// Builds the native proxy configurations for a proxy endpoint.
    /// Returns nil for SOCKS4 (no native representation) or invalid input.
    public static func nativeProxyConfigurations(
        for configuration: ProxyConfiguration
    ) -> [Network.ProxyConfiguration]? {
        guard configuration.type != .socks4 else { return nil }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: configuration.port)) else {
            return nil
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ProxyConfigurationValidator.normalizedHost(configuration.host)),
            port: port
        )
        let username = configuration.requiresAuthentication ? configuration.username : nil
        let password = configuration.requiresAuthentication ? configuration.password : nil

        let proxy: Network.ProxyConfiguration
        switch configuration.type {
        case .socks5:
            proxy = Network.ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:
            proxy = Network.ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case .https:
            let tlsOptions = NWProtocolTLS.Options()
            proxy = Network.ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: tlsOptions)
        case .socks4:
            return nil
        }

        if let username, let password, !username.isEmpty, !password.isEmpty {
            // NOTE: Apple's native proxy APIs do not carry credentials on the
            // ProxyConfiguration itself; authenticated SOCKS5/HTTP proxies are
            // therefore only routed by Transport (raw), not by these sessions.
        }
        return [proxy]
    }

    /// Applies a native proxy to a URLSessionConfiguration with strict
    /// no-failover semantics: a failed proxy is a failed request — the system
    /// must NEVER silently fall back to a direct connection.
    @available(iOS 17.0, *)
    public static func apply(
        _ configurations: [Network.ProxyConfiguration],
        to sessionConfiguration: URLSessionConfiguration
    ) {
        sessionConfiguration.proxyConfigurations = configurations
    }
}

// MARK: - ProxySessionProvider
//
// Single place that builds proxy-aware `URLSessionConfiguration`s for the
// Download engine and the Browser layer. Owns the local SOCKS4→SOCKS5
// adapter. `allowFailover` is always false once a proxy applies.

@MainActor
public final class ProxySessionProvider: ObservableObject {

    private let adapter = LocalSOCKS5Adapter()

    public init() {}

    /// Ephemeral configuration through the given proxy (nil → direct).
    public func sessionConfiguration(for configuration: ProxyConfiguration?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        applyProxy(configuration, to: config)
        return config
    }

    /// Applies the proxy to an existing configuration. When the proxy is
    /// SOCKS4 the local adapter is (re)started and its loopback SOCKS5
    /// endpoint is used. On any failure the configuration has NO proxy and
    /// `lastAdapterError` is set so the caller can surface a useful error.
    @discardableResult
    public func applyProxy(_ configuration: ProxyConfiguration?, to sessionConfiguration: URLSessionConfiguration) -> ProxyTestFailure? {
        if let configuration {
            if configuration.type == .socks4 {
                if let endpoint = adapter.start(upstream: configuration) {
                    let proxy = Network.ProxyConfiguration(
                        socksv5Proxy: NWEndpoint.hostPort(host: "127.0.0.1", port: endpoint)
                    )
                    ProxyNetworkConfigurationBuilder.apply([proxy], to: sessionConfiguration)
                    return nil
                }
                sessionConfiguration.proxyConfigurations = []
                return .proxyUnavailable
            }
            if let native = ProxyNetworkConfigurationBuilder.nativeProxyConfigurations(for: configuration), !native.isEmpty {
                ProxyNetworkConfigurationBuilder.apply(native, to: sessionConfiguration)
                return nil
            }
            sessionConfiguration.proxyConfigurations = []
            return .invalidConfiguration("Proxy could not be represented for this session")
        }
        sessionConfiguration.proxyConfigurations = []
        return nil
    }

    public func stopAdapter() {
        adapter.stop()
    }
}

// MARK: - LocalSOCKS5Adapter
//
// "FluxDL Proxy Adapter": a local SOCKS5 endpoint on loopback that bridges to
// an upstream SOCKS4/SOCKS4a server. This is how SOCKS4 proxies gain access
// to Apple's native `ProxyConfiguration(socksv5Proxy:)` path.
//
//   Browser / Downloads (native)  →  127.0.0.1:port (SOCKS5, no auth)
//                                          ↓ adapter
//                                   Upstream SOCKS4 / SOCKS4a
//                                          ↓
//                                        Destination
//
// IPv6 destinations are rejected cleanly (SOCKS4 has no IPv6 encoding).

public final class LocalSOCKS5Adapter {

    private var listener: NWListener?
    private var activePort: UInt16?
    private var upstreamKey: String?
    private let queue = DispatchQueue(label: "com.rakib.FluxDL.socks4.adapter")
    private var tunnels: [ObjectIdentifier: AdapterTunnel] = [:]

    public init() {}

    /// Starts (or reuses) the local SOCKS5 listener bridging to `upstream`.
    /// Returns the loopback endpoint to put in the client configuration.
    public func start(upstream: ProxyConfiguration) -> NWEndpoint.Port? {
        let key = upstream.fingerprint
        if let listener, upstreamKey == key,
           let activePort,
           let endpoint = NWEndpoint.Port(rawValue: activePort) {
            return endpoint
        }
        stop()

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: upstream.port)) else { return nil }
        let upstreamEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ProxyConfigurationValidator.normalizedHost(upstream.host)),
            port: port
        )

        // Bind to a concrete free port: an ephemeral listener (port 0) only
        // reports its assigned port asynchronously after `.ready`, which is
        // useless to the caller (and to a reused adapter) here.
        guard let localPort = Self.findFreeTCPPort(),
              let localEndpoint = NWEndpoint.Port(rawValue: localPort) else { return nil }

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: localEndpoint)
        } catch {
            return nil
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleInbound(connection, upstreamEndpoint: upstreamEndpoint, userID: upstream.username)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.stop()
            }
        }
        listener.start(queue: queue)

        self.listener = listener
        self.activePort = localPort
        self.upstreamKey = key
        return localEndpoint
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        upstreamKey = nil
        for tunnel in tunnels.values { tunnel.cancel() }
        tunnels.removeAll()
    }

    /// Picks a free TCP port on loopback by binding a throwaway socket.
    /// The socket is released before `NWListener` binds, so the result is
    /// advisory (tiny TOCTOU window) — the listener's `.failed` handler
    /// clears the adapter if the bind races.
    private static func findFreeTCPPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else { return nil }

        var boundAddr = addr
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(fd, withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &length) == 0 else { return nil }

        return UInt16(bigEndian: boundAddr.sin_port)
    }

    // MARK: - Inbound

    private func handleInbound(_ connection: NWConnection, upstreamEndpoint: NWEndpoint, userID: String) {
        let tunnel = AdapterTunnel(
            inbound: connection,
            upstreamEndpoint: upstreamEndpoint,
            userID: userID,
            queue: queue
        ) { [weak self] tunnel in
            self?.tunnels[tunnel.id] = nil
        }
        tunnels[tunnel.id] = tunnel
        tunnel.start()
    }
}

// MARK: - AdapterTunnel
//
// Per-connection bridge: completes the local SOCKS5 handshake, dials the
// upstream SOCKS4/4a server, then relays bytes in both directions.

private final class AdapterTunnel {
    let id: ObjectIdentifier
    private let inbound: NWConnection
    private let upstreamEndpoint: NWEndpoint
    private let userID: String
    private let queue: DispatchQueue
    private let onFinish: (AdapterTunnel) -> Void
    private var upstream: NWConnection?

    init(
        inbound: NWConnection,
        upstreamEndpoint: NWEndpoint,
        userID: String,
        queue: DispatchQueue,
        onFinish: @escaping (AdapterTunnel) -> Void
    ) {
        self.id = ObjectIdentifier(self)
        self.inbound = inbound
        self.upstreamEndpoint = upstreamEndpoint
        self.userID = userID
        self.queue = queue
        self.onFinish = onFinish
    }

    func start() {
        inbound.start(queue: queue)
        readGreeting()
    }

    // MARK: - Local SOCKS5 greeting

    private func readGreeting() {
        receiveExactly(inbound, 2) { [weak self] data in
            guard let self, let data, data.count == 2, data[0] == 0x05 else {
                self?.cancel()
                return
            }
            let methodCount = Int(data[1])
            self.receiveExactly(self.inbound, methodCount) { [weak self] methods in
                guard let self, let methods, methods.count == methodCount else {
                    self?.cancel()
                    return
                }
                // Only "no authentication" is offered on the loopback endpoint.
                if methods.contains(0x00) {
                    self.send(self.inbound, Data([0x05, 0x00]))
                    self.readConnectRequest()
                } else {
                    self.send(self.inbound, Data([0x05, 0xFF]))
                    self.cancel()
                }
            }
        }
    }

    private func readConnectRequest() {
        receiveExactly(inbound, 4) { [weak self] data in
            guard let self, let data, data.count == 4, data[0] == 0x05, data[1] == 0x01 else {
                self?.cancel()
                return
            }
            let atyp = data[3]
            switch atyp {
            case 0x01: // IPv4
                self.receiveExactly(self.inbound, 4) { address in
                    guard let address = address, address.count == 4 else {
                        self.cancel()
                        return
                    }
                    let ip = address.map { String($0) }.joined(separator: ".")
                    self.receivePortAndConnect(host: ip)
                }
            case 0x03: // domain (remote DNS path)
                self.receiveExactly(self.inbound, 1) { [weak self] lengthData in
                    guard let self, let lengthData, let length = lengthData.first else {
                        self?.cancel()
                        return
                    }
                    let hostLength = Int(length)
                    self.receiveExactly(self.inbound, hostLength) { [weak self] hostData in
                        guard let self, let hostData, hostData.count == hostLength,
                              let host = String(data: hostData, encoding: .utf8) else {
                            self?.cancel()
                            return
                        }
                        self.receivePortAndConnect(host: host)
                    }
                }
            case 0x04: // IPv6 — not expressible in SOCKS4
                self.send(self.inbound, Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                self.cancel()
            default:
                self.send(self.inbound, Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                self.cancel()
            }
        }
    }

    private func receivePortAndConnect(host: String) {
        receiveExactly(inbound, 2) { [weak self] portData in
            guard let self, let portData, portData.count == 2 else {
                self?.cancel()
                return
            }
            let port = UInt16(portData[0]) << 8 | UInt16(portData[1])
            self.dialUpstream(host: host, port: port)
        }
    }

    // MARK: - Upstream SOCKS4/4a

    private func dialUpstream(host: String, port: UInt16) {
        let connection = NWConnection(to: upstreamEndpoint, using: .tcp)
        self.upstream = connection
        connection.start(queue: queue)

        var ipv4 = in_addr()
        let isIPv4Literal = inet_pton(AF_INET, host, &ipv4) == 1

        var request = Data([0x04, 0x01])
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
        if isIPv4Literal {
            withUnsafeBytes(of: &ipv4) { request.append(contentsOf: $0) }
        } else {
            request.append(contentsOf: [0, 0, 0, 1]) // SOCKS4a marker
        }
        request.append(contentsOf: Array(userID.utf8))
        request.append(0)
        if !isIPv4Literal {
            request.append(contentsOf: Array(host.utf8))
            request.append(0)
        }

        var ready = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready = true
                connection.send(content: request, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.replyConnectFailed()
                        self.cancel()
                        return
                    }
                    self.receiveUpstreamReply()
                })
            case .failed, .cancelled:
                if !ready {
                    self.replyConnectFailed()
                    self.cancel()
                }
            default:
                break
            }
        }
    }

    private func receiveUpstreamReply() {
        guard let upstream else { return }
        receiveExactly(upstream, 8) { [weak self] data in
            guard let self else { return }
            guard let data, data.count == 8, data[0] == 0x00, data[1] == 90 else {
                self.replyConnectFailed()
                self.cancel()
                return
            }
            // Local SOCKS5 success reply (rep 0x00, bound 0.0.0.0:0).
            self.send(self.inbound, Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            self.beginRelay()
        }
    }

    private func replyConnectFailed() {
        send(inbound, Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    }

    // MARK: - Relay

    private func beginRelay() {
        guard let upstream else { return }
        relay(from: upstream, to: inbound)
        relay(from: inbound, to: upstream)
    }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    if sendError != nil {
                        self?.cancel()
                        return
                    }
                    self?.relay(from: source, to: destination)
                })
            } else if error != nil || isComplete {
                self.cancel()
            }
        }
    }

    func cancel() {
        inbound.cancel()
        upstream?.cancel()
        onFinish(self)
    }

    // MARK: - Low-level helpers

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveExactly(
        _ connection: NWConnection,
        _ count: Int,
        completion: @escaping (Data?) -> Void
    ) {
        receiveExactlyInternal(connection, remaining: count, accumulated: Data(), completion: completion)
    }

    private func receiveExactlyInternal(
        _ connection: NWConnection,
        remaining: Int,
        accumulated: Data,
        completion: @escaping (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, _ in
            guard let self else {
                completion(nil)
                return
            }
            guard let data, !data.isEmpty else {
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