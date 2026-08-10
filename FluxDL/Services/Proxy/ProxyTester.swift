import Foundation

// MARK: - ProxyTester
//
// Professional end-to-end proxy tester. NEVER uses ICMP ping: a reachable
// proxy that cannot proxy traffic is reported as failed.
//
// Measures (per section 17 of the spec):
//   * TCP            — raw TCP connection time to the proxy
//   * Proxy handshake — SOCKS/HTTP CONNECT negotiation time
//   * Request        — end-to-end HTTP request through the tunnel
//   * Exit IP        — destination-observed IP when the probe returns one
//
// The probe request is a plaintext HTTP exchange through the tunnel, so it
// works identically through SOCKS4/4a, SOCKS5 and HTTP(S) CONNECT proxies.
// End-to-end TLS verification of real sessions is covered by
// `ProxyEffectivenessChecker`, which routes a URLSession through the SAME
// configuration the Downloads/Browser layers use.

public enum ProxyTester {

    /// Default probe endpoint. Returns the caller's public IP as plain text
    /// over plain HTTP (no redirects), which tunnels cleanly through every
    /// supported proxy type.
    public static let defaultTestURL = URL(string: "http://api.ipify.org")!

    /// Fallback endpoints tried when the primary probe fails.
    public static let fallbackTestURLs = [
        "http://api.ipify.org",
        "http://ifconfig.me/ip",
        "http://icanhazip.com"
    ]

    /// Maximum simultaneous probe connections (bulk tests).
    public static let testConcurrencyLimit = 4
    /// Maximum bytes read for a probe response body.
    private static let maxResponseBodyBytes = 8 * 1024

    /// Runs a full end-to-end test through the given proxy.
    public static func test(
        _ configuration: ProxyConfiguration,
        timeout: TimeInterval = 10
    ) async -> ProxyTestResult {
        if let issue = ProxyConfigurationValidator.validate(configuration) {
            return ProxyTestResult.failure(.invalidConfiguration(issue))
        }

        var lastResult: ProxyTestResult?
        var seen = Set<String>()
        let candidates = [defaultTestURL] + fallbackTestURLs.compactMap(URL.init(string:))
        let uniqueCandidates = candidates.filter { seen.insert($0.absoluteString).inserted }
        for url in uniqueCandidates {
            let result = await probe(configuration, url: url, timeout: timeout)
            lastResult = result
            if result.success { return result }
        }
        // All probes failed — report the most meaningful failure.
        guard let lastResult else {
            return ProxyTestResult.failure(.connectionFailed)
        }
        return lastResult
    }

    // MARK: - Single probe

    private static func probe(
        _ configuration: ProxyConfiguration,
        url: URL,
        timeout: TimeInterval
    ) async -> ProxyTestResult {
        guard let host = url.host, !host.isEmpty else {
            return ProxyTestResult.failure(.invalidConfiguration("Invalid test URL"))
        }
        let port = UInt16(url.port ?? 80)
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")

        do {
            let tunnel = try await ProxyTunnel.open(
                configuration,
                targetHost: host,
                targetPort: port,
                timeout: timeout
            )
            let stream = tunnel.stream
            defer { stream.close() }

            let request = Self.httpRequest(method: "GET", host: host, port: port, path: path)
            let requestStart = Date()
            try await stream.send(Data(request.utf8))

            let response = try await Self.readResponse(on: stream)
            let requestMs = max(1, Int((Date().timeIntervalSince(requestStart) * 1000).rounded()))

            guard let status = response.statusCode else {
                return ProxyTestResult.failure(.protocolError)
            }
            guard (200...299).contains(status) else {
                if status == 407 {
                    return ProxyTestResult.failure(.httpAuthenticationFailed, tcpMs: tunnel.handshake.tcpMs, handshakeMs: tunnel.handshake.handshakeMs)
                }
                return ProxyTestResult.failure(.destinationConnectionFailed, tcpMs: tunnel.handshake.tcpMs, handshakeMs: tunnel.handshake.handshakeMs)
            }

            let exitIP = Self.plausibleIP(from: response.body)
            return ProxyTestResult.success(
                latencyMs: requestMs,
                tcpMs: tunnel.handshake.tcpMs,
                handshakeMs: tunnel.handshake.handshakeMs,
                requestMs: requestMs,
                exitIP: exitIP
            )
        } catch let failure where failure is ProxyTestFailure {
            return ProxyTestResult.failure(failure as! ProxyTestFailure)
        } catch is CancellationError {
            return ProxyTestResult.failure(.timedOut)
        } catch {
            return ProxyTestResult.failure(.connectionFailed)
        }
    }

    // MARK: - HTTP plumbing

    private static func httpRequest(method: String, host: String, port: UInt16, path: String) -> String {
        var composed = "\(method) \(path) HTTP/1.1\r\n"
        composed += "Host: \(ProxyConfigurationValidator.bracketedHost(host)):\(port)\r\n"
        composed += "User-Agent: FluxDL/1.0\r\n"
        composed += "Accept: text/plain, */*\r\n"
        composed += "Connection: close\r\n\r\n"
        return composed
    }

    private struct HTTPResponse {
        var statusCode: Int?
        var body: Data = Data()
    }

    private static func readResponse(on stream: ProxyStream) async throws -> HTTPResponse {
        var response = HTTPResponse()
        let headerData = try await stream.receiveUntilHeaderEnd()
        var sentinel: Data = headerData

        // Some servers send the body immediately after headers.
        if let text = String(data: headerData, encoding: .utf8) {
            let contentLength = parseContentLength(from: text)
            let headerEnd = text.range(of: "\r\n\r\n")?.upperBound
            let headerPrefix = headerEnd.map { text[..<$0] } ?? text[...]
            if let headerEnd {
                let earlyBody = text[headerEnd...]
                if let data = earlyBody.data(using: .utf8), !data.isEmpty {
                    response.body = data
                    sentinel = Data()
                }
            }
            if let firstLine = headerPrefix.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first {
                let parts = firstLine.split(separator: " ")
                if parts.count >= 2, parts[0].hasPrefix("HTTP/") {
                    response.statusCode = Int(parts[1])
                }
            }
            if response.body.isEmpty, let contentLength {
                let remaining = min(contentLength, Self.maxResponseBodyBytes)
                let body = try await stream.receiveExactly(remaining)
                response.body = body
            }
        }
        // Defence-in-depth: cap the buffer size.
        if response.body.isEmpty, !sentinel.isEmpty {
            response.body = Data(sentinel.prefix(Self.maxResponseBodyBytes))
        }
        if response.body.count > Self.maxResponseBodyBytes {
            response.body = response.body.prefix(Self.maxResponseBodyBytes)
        }
        return response
    }

    private static func parseContentLength(from headerText: String) -> Int? {
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Accepts only IPv4/IPv6 literals as an exit IP — never renders junk.
    private static func plausibleIP(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let compact = text.replacingOccurrences(of: "\u{200E}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty, compact.count <= 45 else { return nil }
        if ProxyConfigurationValidator.isIPv4(compact) || ProxyConfigurationValidator.isIPv6(compact) {
            return compact
        }
        return nil
    }
}

// MARK: - ProxyBulkTester
//
// Runs Test-All with bounded concurrency, per-item progress and cancellation.
// Never opens more than `concurrency` simultaneous probe connections.

public enum ProxyBulkTester {

    public struct Item: Sendable {
        public let id: UUID
        public let configuration: ProxyConfiguration
    }

    public static func testAll(
        _ items: [Item],
        timeout: TimeInterval = 10,
        concurrency: Int = ProxyTester.testConcurrencyLimit,
        progress: @Sendable (_ completed: Int, _ total: Int, _ succeeded: Int) -> Void = { _, _, _ in }
    ) async -> [UUID: ProxyTestResult] {
        guard !items.isEmpty else { return [:] }
        let limit = max(1, min(concurrency, ProxyTester.testConcurrencyLimit))

        var results: [UUID: ProxyTestResult] = [:]
        var completed = 0
        var succeeded = 0
        let total = items.count

        let batches = stride(from: 0, to: items.count, by: limit).map {
            Array(items[$0..<min($0 + limit, items.count)])
        }

        for batch in batches {
            let outcomes = await withTaskGroup(of: (UUID, ProxyTestResult).self) { group in
                for item in batch {
                    group.addTask {
                        let result = await ProxyTester.test(item.configuration, timeout: timeout)
                        return (item.id, result)
                    }
                }
                var outcomes: [(UUID, ProxyTestResult)] = []
                for await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }
            for (id, result) in outcomes {
                results[id] = result
                completed += 1
                if result.success { succeeded += 1 }
                progress(completed, total, succeeded)
            }
            if Task.isCancelled { break }
        }
        return results
    }
}

// MARK: - ProxyEffectivenessChecker
//
// The critical "is it actually working?" verification: does REAL traffic
// (a URLSession built from the same configuration the Downloads and Browser
// layers use) exit through the proxy?
//
//   * Direct IP != Proxy IP            → proxy working
//   * Proxy request fails              → proxy ineffective / failed
//   * Direct IP == Proxy IP            → traffic still leaving directly

public enum ProxyEffectivenessChecker {

    public static let exitIPTestsURL = URL(string: "http://api.ipify.org")!

    public struct Result: Equatable, Sendable {
        public let directIP: String?
        public let proxyIP: String?

        public init(directIP: String?, proxyIP: String?) {
            self.directIP = directIP
            self.proxyIP = proxyIP
        }

        /// True when a proxy-session request succeeded via an address that
        /// differs from the direct address (or direct has no address at all).
        public var isEffective: Bool {
            guard let proxyIP else { return false }
            if let directIP { return proxyIP != directIP }
            return true
        }

        public var statusText: String {
            if let proxyIP, let directIP, proxyIP != directIP {
                return "Proxy working (exit \(proxyIP))"
            }
            if let proxyIP {
                return "Direct \(proxyIP) — proxy ineffective"
            }
            return "Proxy failed — request did not complete"
        }
    }

    /// Fetches the public IP through a URLSession built exactly like the
    /// ones used for proxied downloads/browser traffic.
    public static func check(
        sessionConfiguration: URLSessionConfiguration,
        url: URL = exitIPTestsURL,
        timeout: TimeInterval = 15,
        directIP: String? = nil
    ) async -> Result {
        var direct = directIP
        if direct == nil {
            direct = await fetchIP(configuration: nil, url: url, timeout: timeout)
        }
        if sessionConfiguration.proxyConfigurations.isEmpty {
            return Result(directIP: direct, proxyIP: direct)
        }
        let proxy = await fetchIP(configuration: sessionConfiguration, url: url, timeout: timeout)
        return Result(directIP: direct, proxyIP: proxy)
    }

    private static func fetchIP(configuration: URLSessionConfiguration?, url: URL, timeout: TimeInterval) async -> String? {
        let session: URLSession
        if let configuration {
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            session = URLSession(configuration: configuration)
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            session = URLSession(configuration: config)
        }
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if ProxyConfigurationValidator.isIPv4(text) || ProxyConfigurationValidator.isIPv6(text) {
                return text
            }
            return nil
        } catch {
            return nil
        }
    }
}