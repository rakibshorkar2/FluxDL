import Foundation

// MARK: - URL intelligence

/// Network-free header parsing plus a lightweight network probe used to learn
/// about a URL before downloading it. The probe never downloads the body: it
/// issues HEAD (or a 1-byte ranged GET when HEAD is unsupported) and cancels
/// as soon as headers arrive, so adding a download is never delayed.
public enum DownloadURLIntelligence {

    /// Normalizes Foundation's `[AnyHashable: Any]` headers into a
    /// case-insensitive `[String: String]` map.
    public static func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let stringKey = key as? String, let stringValue = value as? String else { continue }
            result[stringKey.lowercased()] = stringValue
        }
        return result
    }

    /// Parses Content-Length, tolerating commas and malformed values.
    public static func parseContentLength(_ value: String?) -> Int64? {
        guard let value else { return nil }
        let cleaned = value.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .joined()
        return Int64(cleaned)
    }

    public static func parseAcceptsRanges(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.lowercased().contains("bytes")
    }

    public static func parseBool(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return defaultValue
        }
    }

    /// Builds a `DownloadProbeResult` from an HTTP response without I/O.
    public static func probeResult(
        from response: HTTPURLResponse,
        finalURL: URL? = nil,
        redirectCount: Int = 0,
        requiresAuthentication: Bool = false
    ) -> DownloadProbeResult {
        let headers = normalizedHeaders(from: response)
        let contentDisposition = headers["content-disposition"]
        let filename = URLFilenameExtractor.extractFilename(
            from: finalURL ?? response.url ?? URL(string: "https://example.invalid")!,
            contentDisposition: contentDisposition
        )
        let status = response.statusCode
        let url = finalURL ?? response.url
        return DownloadProbeResult(
            httpStatus: status,
            finalURL: url,
            contentLength: parseContentLength(headers["content-length"]),
            mimeType: headers["content-type"],
            filename: filename,
            contentDisposition: contentDisposition,
            acceptsRanges: parseAcceptsRanges(headers["accept-ranges"]),
            etag: headers["etag"],
            lastModified: headers["last-modified"],
            serverName: headers["server"],
            redirectCount: redirectCount,
            requiresAuthentication: requiresAuthentication,
            expirationRisk: url.flatMap { DownloadExpirationRisk.from(url: $0) } ?? .unknown,
            headers: headers,
            probedAt: Date()
        )
    }

    /// Consistency check for a probe used to validate a resume: the server's
    /// identity markers (ETag/Last-Modified/Length) must not contradict the
    /// ones stored when the partial data was written.
    public static func resumeValidation(
        storedETag: String?,
        storedLastModified: String?,
        storedLength: Int64?,
        probe: DownloadProbeResult
    ) -> ResumeConsistency {
        if let stored = storedETag, !stored.isEmpty,
           let fresh = probe.etag, !fresh.isEmpty, stored != fresh {
            return .changedETag
        }
        if let stored = storedLastModified, !stored.isEmpty,
           let fresh = probe.lastModified, !fresh.isEmpty, stored != fresh {
            return .changedLastModified
        }
        if let stored = storedLength, let fresh = probe.contentLength, fresh > 0,
           fresh < stored {
            return .serverShrunk
        }
        return .consistent
    }

    public enum ResumeConsistency: String, Sendable, Equatable {
        case consistent = "Consistent"
        case changedETag = "ETag Changed"
        case changedLastModified = "Last Modified Changed"
        case serverShrunk = "Server File Shrunk"
    }
}

// MARK: - Network probe

/// Runs the lightweight probe. Safe to call from anywhere; the returned
/// result is only used for strategy decisions, so a failed probe simply
/// means "no metadata" (normal download path).
public final class DownloadProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    public struct Options: Sendable {
        public var requestTimeout: TimeInterval
        public var overallTimeout: TimeInterval
        public var maxRedirects: Int
        public init(
            requestTimeout: TimeInterval = 8,
            overallTimeout: TimeInterval = 15,
            maxRedirects: Int = 5
        ) {
            self.requestTimeout = requestTimeout
            self.overallTimeout = overallTimeout
            self.maxRedirects = maxRedirects
        }
    }

    private let url: URL
    private let options: Options
    private var session: URLSession?
    private var currentTask: URLSessionTask?
    private var capturedResponse: HTTPURLResponse?
    private var redirectCount = 0
    private var requiresAuthentication = false
    private var continuation: CheckedContinuation<DownloadProbeResult?, Never>?
    private let queue = DispatchQueue(label: "fluxdl.probe", qos: .userInitiated)
    private var didFinish = false

    public init(url: URL, options: Options = Options()) {
        self.url = url
        self.options = options
        super.init()
    }

    /// Runs the probe. Returns nil on any failure — the caller treats that as
    /// "no metadata" and uses the reliable normal path.
    public func probe() async -> DownloadProbeResult? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = options.requestTimeout
        configuration.timeoutIntervalForResource = options.overallTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        let outcome = await withCheckedContinuation { continuation in
            self.continuation = continuation
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                var request = URLRequest(url: self.url)
                request.httpMethod = "HEAD"
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = self.options.requestTimeout
                let task = session.dataTask(with: request)
                self.currentTask = task
                task.resume()
            }
        }
        session.invalidateAndCancel()
        return outcome
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectCount += 1
        if redirectCount > options.maxRedirects {
            completionHandler(nil)
            finish(result: nil)
            return
        }
        completionHandler(request)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Basic/Digest/NTLM/Default prompts or expired credentials: mark the
        // URL as requiring authentication, never prompt inside a probe.
        requiresAuthentication = true
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(result: nil)
            return
        }
        capturedResponse = http
        // HEAD responses carry no body; the GET fallback is cancelled after
        // the first data chunk. Never let the probe pull the full file.
        completionHandler(.cancel)
        finish(result: DownloadURLIntelligence.probeResult(
            from: http,
            finalURL: response.url,
            redirectCount: redirectCount,
            requiresAuthentication: requiresAuthentication
        ))
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // If the server ignored our HEAD and streams a body, cancel at once.
        finish(result: capturedResponse.map {
            DownloadURLIntelligence.probeResult(
                from: $0,
                finalURL: $0.url,
                redirectCount: redirectCount,
                requiresAuthentication: requiresAuthentication
            )
        })
        currentTask?.cancel()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = capturedResponse {
            finish(result: DownloadURLIntelligence.probeResult(
                from: http,
                finalURL: http.url,
                redirectCount: redirectCount,
                requiresAuthentication: requiresAuthentication
            ))
        } else {
            finish(result: nil)
        }
    }

    private func finish(result: DownloadProbeResult?) {
        queue.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.didFinish = true
            self.continuation?.resume(returning: result)
            self.continuation = nil
        }
    }
}

// MARK: - Strategy decision for a fresh URL

extension DownloadStrategyEngine {

    /// One-call convenience used by the engine: probe (if quick) and decide.
    /// Probing never blocks the actual transfer — a slow probe simply yields
    /// the normal strategy.
    public static func decide(
        for url: URL,
        existingBytes: Int64,
        segmentedEnabled: Bool,
        proxiedRouteActive: Bool,
        probeTimeout: TimeInterval = 8
    ) async -> Recommendation {
        let probe = await DownloadProbe(url: url, options: DownloadProbe.Options(requestTimeout: probeTimeout)).probe()
        return recommend(
            probe: probe,
            url: url,
            existingBytes: existingBytes,
            segmentedEnabled: segmentedEnabled,
            proxiedRouteActive: proxiedRouteActive
        )
    }
}
