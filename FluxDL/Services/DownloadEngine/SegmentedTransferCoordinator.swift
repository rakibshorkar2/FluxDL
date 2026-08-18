import Foundation

// MARK: - Delegate

/// Callbacks from the segmented coordinator to the engine. All are delivered
/// on the main actor, matching the engine's `@MainActor` surface.
public protocol SegmentedTransferDelegate: AnyObject {
    func segmentedCoordinator(_ coordinator: SegmentedTransferCoordinator, progress taskID: UUID, downloaded: Int64, total: Int64, averageSpeed: Double, remaining: TimeInterval, health: DownloadHealthSnapshot?)
    func segmentedCoordinator(_ coordinator: SegmentedTransferCoordinator, completed taskID: UUID, assembledURL: URL, finalSize: Int64)
    func segmentedCoordinator(_ coordinator: SegmentedTransferCoordinator, failed taskID: UUID, message: String, needsAttention: Bool)
    /// Cancel all segments; the engine re-runs its reliable normal path.
    func segmentedCoordinator(_ coordinator: SegmentedTransferCoordinator, needsFallback taskID: UUID, reason: String)
    func segmentedCoordinator(_ coordinator: SegmentedTransferCoordinator, paused taskID: UUID, segments: [DownloadSegment])
    func segmentedCoordinator(_ coordinator: SegmentedTransferCoordinator, needsRepair taskID: UUID, segments: [DownloadSegment], serverSize: Int64)
}

// MARK: - Coordinator

/// Coordinates multi-connection (byte-range) downloads for tasks the engine
/// decides are segmentable. Foreground `URLSessionDataTask`s with explicit
/// `Range:` headers; per-segment `.part` files under the temp directory;
/// streaming assembly + atomic finalize; 416 repair; adaptive retry using the
/// shared classification table; background/pause-safe resumable state.
///
/// No Apple background guarantees exist for custom segmented networking: on
/// app background the engine pauses segment sessions (see `pauseForBackground`)
/// and they resume through the normal queue machinery. The proxy is never
/// silently bypassed — the engine refuses segmented routing while a proxy
/// route is active.
@MainActor
public final class SegmentedTransferCoordinator: NSObject {

    public weak var delegate: SegmentedTransferDelegate?

    /// Mutable per-segment state; only touched on the delegate queue.
    fileprivate final class TransferSegment: @unchecked Sendable {
        var segment: DownloadSegment
        let partURL: URL
        var fileHandle: FileHandle?
        weak var dataTask: URLSessionDataTask?
        var requestStartedAt: Date?
        var wroteBytes: Int64 = 0
        var responded206 = false
        var contentRangeStart: Int64?
        var contentRangeEnd: Int64?

        init(segment: DownloadSegment, partURL: URL) {
            self.segment = segment
            self.partURL = partURL
        }
    }

    /// Mutable per-task session; only touched on the delegate queue.
    fileprivate final class Session: @unchecked Sendable {
        let taskID: UUID
        let url: URL
        var totalBytes: Int64
        var segments: [UUID: TransferSegment] = [:]
        let monitor = DownloadHealthMonitor()
        var lastReport = Date()
        var retryBudget: DownloadRetryEngine.Budget
        var throttler = SegmentedThrottleController()

        init(taskID: UUID, url: URL, totalBytes: Int64, retryBudget: DownloadRetryEngine.Budget) {
            self.taskID = taskID
            self.url = url
            self.totalBytes = totalBytes
            self.retryBudget = retryBudget
        }
    }

    /// Everything reachable from the delegate queue.
    fileprivate final class Store: @unchecked Sendable {
        let queue = DispatchQueue(label: "fluxdl.segmented.delegate", qos: .utility)
        var sessions: [UUID: Session] = [:]
        var taskIDByTaskIdentifier: [Int: UUID] = [:]
        weak var session: URLSession?
    }

    private let store = Store()
    private var urlSession: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 0
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = store.queue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        urlSession = session
        store.session = session
    }

    // MARK: - Public API (MainActor)

    public func isHandling(_ taskID: UUID) -> Bool {
        store.queue.sync { store.sessions[taskID] != nil }
    }

    public func activeTaskIDs() -> [UUID] {
        store.queue.sync { Array(store.sessions.keys) }
    }

    /// Starts (or resumes) a segmented transfer. `segments` may carry
    /// previously downloaded bytes; sizes are reconciled with the `.part`
    /// files on disk so drifted offsets never corrupt assembly.
    public func start(
        taskID: UUID,
        url: URL,
        segments: [DownloadSegment],
        totalBytes: Int64,
        retryBudget: DownloadRetryEngine.Budget = DownloadRetryEngine.Budget()
    ) {
        store.queue.async { [weak self] in
            guard let self else { return }
            let partDirectory = Self.partDirectory(for: taskID)
            try? FileManager.default.createDirectory(at: partDirectory, withIntermediateDirectories: true)
            let session = Session(taskID: taskID, url: url, totalBytes: totalBytes, retryBudget: retryBudget)
            for segment in segments where segment.state != .completed && segment.state != .cancelled {
                let partURL = partDirectory
                    .appendingPathComponent(segment.segmentID.uuidString)
                    .appendingPathExtension("part")
                var reconciled = segment
                reconciled.downloadedBytes = Self.fileSize(partURL: partURL)
                if reconciled.downloadedBytes >= reconciled.expectedBytes {
                    reconciled.state = .completed
                    session.segments[segment.segmentID] = TransferSegment(segment: reconciled, partURL: partURL)
                    continue
                }
                if reconciled.state == .pending || reconciled.state == .retrying {
                    reconciled.state = .downloading
                }
                session.segments[segment.segmentID] = TransferSegment(segment: reconciled, partURL: partURL)
            }
            guard !session.segments.isEmpty else {
                self.finishSessionOnQueue(taskID: taskID, mode: .fallback(reason: "No segmentable bytes"))
                return
            }
            store.sessions[taskID] = session
            for (segmentID, transfer) in session.segments where transfer.segment.state == .downloading || transfer.segment.state == .paused {
                transfer.segment.state = .downloading
                startDataTask(in: session, segmentID: segmentID)
            }
        }
    }

    /// Cancels all segment tasks, collecting the latest state for persistence.
    /// Completion is reported asynchronously via `delegate.paused`.
    public func pause(taskID: UUID) {
        store.queue.async { [weak self] in
            guard let self, let session = self.store.sessions[taskID] else { return }
            for transfer in session.segments.values {
                transfer.segment.state = .paused
                transfer.fileHandle?.closeFile()
                transfer.fileHandle = nil
                transfer.dataTask?.cancel()
                transfer.dataTask = nil
            }
            let finalSegments = session.segments.values
                .map(\.segment)
                .sorted { $0.byteStart < $1.byteStart }
            self.store.sessions.removeValue(forKey: taskID)
            self.store.taskIDByTaskIdentifier = self.store.taskIDByTaskIdentifier.filter { $0.value != taskID }
            self.hopToMain { [weak self] in
                guard let self else { return }
                self.delegate?.segmentedCoordinator(self, paused: taskID, segments: finalSegments)
            }
        }
    }

    /// Cancels tasks and removes all segment files for the task.
    public func discard(taskID: UUID, deleteFiles: Bool = false) {
        store.queue.async { [weak self] in
            guard let self, let session = self.store.sessions[taskID] else { return }
            for transfer in session.segments.values {
                transfer.dataTask?.cancel()
                transfer.fileHandle?.closeFile()
            }
            self.store.sessions.removeValue(forKey: taskID)
            self.store.taskIDByTaskIdentifier = self.store.taskIDByTaskIdentifier.filter { $0.value != taskID }
            if deleteFiles {
                try? FileManager.default.removeItem(at: Self.partDirectory(for: taskID))
            }
        }
    }

    /// Pauses every active session (app entering background).
    public func pauseForBackground() {
        let ids = activeTaskIDs()
        for id in ids {
            pause(taskID: id)
        }
    }

    /// Current persisted segment states for a task (for snapshots).
    public func currentSegments(taskID: UUID) -> [DownloadSegment]? {
        store.queue.sync {
            guard let session = store.sessions[taskID] else { return nil }
            return session.segments.values.map(\.segment).sorted { $0.byteStart < $1.byteStart }
        }
    }

    // MARK: - Delegate queue internals

    private func startDataTask(in session: Session, segmentID: UUID) {
        guard let transfer = session.segments[segmentID],
              let range = transfer.segment.nextRangeHeader else { return }
        var request = URLRequest(url: session.url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let dataTask = urlSession.dataTask(with: request)
        transfer.segment.state = .downloading
        transfer.dataTask = dataTask
        transfer.requestStartedAt = Date()
        transfer.responded206 = false
        transfer.contentRangeStart = nil
        transfer.contentRangeEnd = nil
        store.taskIDByTaskIdentifier[dataTask.taskIdentifier] = session.taskID
        dataTask.resume()
    }

    /// Size of the .part file on disk — the source of truth for resumes.
    static func fileSize(partURL: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partURL.path),
              let size = attributes[.size] as? Int64 else {
            return 0
        }
        return max(size, 0)
    }

    static func partDirectory(for taskID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxDLSegments", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    private func hopToMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private enum SessionEndMode {
        case completed(assembledURL: URL, size: Int64)
        case failed(message: String, needsAttention: Bool)
        case fallback(reason: String)
    }

    private func finishSessionOnQueue(taskID: UUID, mode: SessionEndMode) {
        if let session = store.sessions[taskID] {
            for transfer in session.segments.values {
                transfer.dataTask?.cancel()
                transfer.fileHandle?.closeFile()
            }
            store.sessions.removeValue(forKey: taskID)
            store.taskIDByTaskIdentifier = store.taskIDByTaskIdentifier.filter { $0.value != taskID }
        }
        hopToMain { [weak self] in
            guard let self else { return }
            switch mode {
            case .completed(let assembledURL, let size):
                self.delegate?.segmentedCoordinator(self, completed: taskID, assembledURL: assembledURL, finalSize: size)
            case .failed(let message, let needsAttention):
                self.delegate?.segmentedCoordinator(self, failed: taskID, message: message, needsAttention: needsAttention)
            case .fallback(let reason):
                self.delegate?.segmentedCoordinator(self, needsFallback: taskID, reason: reason)
            }
        }
    }

    private func reportProgress(for taskID: UUID) {
        guard let session = store.sessions[taskID] else { return }
        let now = Date()
        guard now.timeIntervalSince(session.lastReport) >= 0.8 else { return }
        session.lastReport = now
        let downloaded = session.segments.values.reduce(0) { $0 + $1.segment.validDownloadedBytes }
        let total = session.totalBytes
        let remaining = total - downloaded
        let speed = session.monitor.immediateSnapshot().averageSpeed
        let eta = speed > 10_000 ? TimeInterval(remaining) / speed : 0
        let health = session.monitor.snapshot(at: now)
        hopToMain { [weak self] in
            guard let self else { return }
            self.delegate?.segmentedCoordinator(
                self,
                progress: taskID,
                downloaded: downloaded,
                total: total,
                averageSpeed: speed,
                remaining: eta,
                health: health
            )
        }
    }

    private func segmentCompleted(taskID: UUID, segmentID: UUID) {
        guard let session = store.sessions[taskID], let transfer = session.segments[segmentID] else { return }
        transfer.fileHandle?.closeFile()
        transfer.fileHandle = nil
        transfer.dataTask = nil
        transfer.segment.state = .completed
        transfer.segment.completedAt = Date()
        checkAssembly(for: taskID)
    }

    private func segmentFailed(taskID: UUID, segmentID: UUID, error: Error?, status: Int? = nil) {
        guard let session = store.sessions[taskID], let transfer = session.segments[segmentID] else { return }
        transfer.fileHandle?.closeFile()
        transfer.fileHandle = nil
        transfer.dataTask = nil
        transfer.segment.retryCount += 1
        transfer.segment.lastError = error?.localizedDescription ?? "HTTP \(status ?? 0) failure"

        let kind: DownloadErrorClassifier.FailureKind
        if let status {
            kind = DownloadErrorClassifier.classify(httpStatus: status)
        } else {
            kind = Self.classify(error: error)
        }
        let evaluation = DownloadRetryEngine.evaluate(
            failure: kind,
            attempted: transfer.segment.retryCount,
            budget: session.retryBudget
        )
        session.retryBudget = evaluation.remainingBudget

        switch evaluation.action {
        case .stop:
            finishSessionOnQueue(taskID: taskID, mode: .failed(message: transfer.segment.lastError ?? "Download failed", needsAttention: false))
        case .needsAttention(let message):
            finishSessionOnQueue(taskID: taskID, mode: .failed(message: message, needsAttention: true))
        case .retry(let delay):
            scheduleRetry(taskID: taskID, segmentID: segmentID, after: delay)
        case .retryCounting(let delay):
            scheduleRetry(taskID: taskID, segmentID: segmentID, after: delay)
        case .revalidate(let delay):
            scheduleRevalidate(taskID: taskID, after: delay)
        case .switchMirror(let delay):
            // Mirror switches are decided by the engine; revalidate instead.
            scheduleRevalidate(taskID: taskID, after: delay)
        }
    }

    private func scheduleRetry(taskID: UUID, segmentID: UUID, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.resumeSegment(taskID: taskID, segmentID: segmentID)
        }
        store.queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resumeSegment(taskID: UUID, segmentID: UUID) {
        guard let session = store.sessions[taskID], let transfer = session.segments[segmentID] else { return }
        guard let range = transfer.segment.nextRangeHeader else {
            transfer.segment.state = .completed
            transfer.segment.completedAt = Date()
            checkAssembly(for: taskID)
            return
        }
        var request = URLRequest(url: session.url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60
        let dataTask = urlSession.dataTask(with: request)
        transfer.segment.state = .downloading
        transfer.dataTask = dataTask
        transfer.requestStartedAt = Date()
        transfer.responded206 = false
        transfer.contentRangeStart = nil
        transfer.contentRangeEnd = nil
        store.taskIDByTaskIdentifier[dataTask.taskIdentifier] = taskID
        dataTask.resume()
    }

    private func scheduleRevalidate(taskID: UUID, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.revalidateTask(taskID: taskID)
        }
        store.queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func revalidateTask(taskID: UUID) {
        guard let session = store.sessions[taskID] else { return }
        let url = session.url
        let totalBytes = session.totalBytes
        let segments = session.segments.values.map(\.segment)
        let targetTaskID = taskID
        Task.detached { [weak self] in
            guard let self else { return }
            let probe = await DownloadProbe(url: url).probe()
            let serverSize = probe?.contentLength
            self.store.queue.async { [weak self] in
                guard let self else { return }
                guard let size = serverSize, size > 0 else {
                    self.finishSessionOnQueue(taskID: targetTaskID, mode: .failed(message: "Server no longer reports a valid file size", needsAttention: false))
                    return
                }
                if size != totalBytes {
                    let map = DownloadSegmentMap(segments: segments, totalBytes: size).repairingAfter416(serverSize: size)
                    self.store.sessions.removeValue(forKey: targetTaskID)
                    self.store.taskIDByTaskIdentifier = self.store.taskIDByTaskIdentifier.filter { $0.value != targetTaskID }
                    self.hopToMain { [weak self] in
                        guard let self else { return }
                        self.delegate?.segmentedCoordinator(self, needsRepair: targetTaskID, segments: map.map.segments, serverSize: size)
                    }
                } else if let session = self.store.sessions[targetTaskID] {
                    for (segmentID, transfer) in session.segments where transfer.segment.state == .failed || transfer.segment.state == .downloading {
                        self.resumeSegment(taskID: targetTaskID, segmentID: segmentID)
                    }
                }
            }
        }
    }

    private func checkAssembly(for taskID: UUID) {
        guard let session = store.sessions[taskID] else { return }
        let segments = session.segments.values.map(\.segment)
        let allComplete = !segments.isEmpty && segments.allSatisfy { $0.isComplete }
        guard allComplete else {
            reportProgress(for: taskID)
            return
        }
        // Validate on-disk sizes before assembling.
        for transfer in session.segments.values {
            let expected = transfer.segment.expectedBytes
            let actual = Self.fileSize(partURL: transfer.partURL)
            guard actual == expected else {
                transfer.segment.state = .failed
                transfer.segment.lastError = "Segment size mismatch: expected \(expected) bytes, found \(actual)"
                segmentFailed(taskID: taskID, segmentID: transfer.segment.segmentID, error: nil)
                return
            }
        }
        let partDirectory = Self.partDirectory(for: taskID)
        let assemblyURL = partDirectory
            .appendingPathComponent("assembled")
            .appendingPathExtension("tmp")
        do {
            try SegmentFileAssembler.assemble(
                segments: segments,
                partDirectory: partDirectory,
                outputURL: assemblyURL
            )
        } catch {
            finishSessionOnQueue(taskID: taskID, mode: .failed(message: "Assembly failed: \(error.localizedDescription)", needsAttention: false))
            return
        }
        let finalSize = segments.reduce(0) { $0 + $1.expectedBytes }
        finishSessionOnQueue(taskID: taskID, mode: .completed(assembledURL: assemblyURL, size: finalSize))
    }

    /// Classifies an error, splitting 416 (range repair) from everything else.
    static func classify(error: Error?) -> DownloadErrorClassifier.FailureKind {
        let nsError = error as NSError?
        if let nsError {
            return DownloadErrorClassifier.classify(
                domain: nsError.domain,
                code: nsError.code,
                underlyingDescription: nsError.localizedDescription
            )
        }
        return .backoff(message: "Unknown transfer error")
    }

    /// "bytes 0-499/12345" → (0, 499, 12345). Tolerates missing total.
    static func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header else { return nil }
        let parts = header.components(separatedBy: "/")
        guard parts.count == 2, parts[0].hasPrefix("bytes ") else { return nil }
        let range = parts[0].dropFirst("bytes ".count)
        let bounds = range.split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else {
            return nil
        }
        let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        return (start, end, total)
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              let taskID = store.taskIDByTaskIdentifier[dataTask.taskIdentifier],
              let transfer = store.sessions[taskID]?.segments.values.first(where: { $0.dataTask === dataTask }) else {
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode
        switch status {
        case 200:
            // Server ignored our Range: cannot segment. Fall back.
            completionHandler(.cancel)
            finishSessionOnQueue(taskID: taskID, mode: .fallback(reason: "Server ignored Range request (HTTP 200)"))
        case 206:
            let headers = DownloadURLIntelligence.normalizedHeaders(from: http)
            guard let (start, end, total) = Self.parseContentRange(headers["content-range"]) else {
                completionHandler(.cancel)
                finishSessionOnQueue(taskID: taskID, mode: .failed(message: "Invalid Content-Range header", needsAttention: false))
                return
            }
            guard start == transfer.segment.resumeStart, end <= transfer.segment.byteEnd else {
                completionHandler(.cancel)
                transfer.segment.state = .failed
                transfer.segment.lastError = "Content-Range mismatch: got \(start)-\(end), expected \(transfer.segment.byteStart)-\(transfer.segment.byteEnd)"
                segmentFailed(taskID: taskID, segmentID: transfer.segment.segmentID, error: nil)
                return
            }
            if total > 0, total != store.sessions[taskID]?.totalBytes {
                completionHandler(.cancel)
                revalidateWithServerSize(taskID: taskID, serverSize: total)
                return
            }
            transfer.responded206 = true
            transfer.contentRangeStart = start
            transfer.contentRangeEnd = end
            if transfer.fileHandle == nil {
                do {
                    let handle = try FileHandle(forWritingTo: transfer.partURL)
                    try handle.seek(toOffset: UInt64(start - transfer.segment.byteStart))
                    transfer.fileHandle = handle
                } catch {
                    completionHandler(.cancel)
                    finishSessionOnQueue(taskID: taskID, mode: .failed(message: "Cannot open segment file", needsAttention: false))
                    return
                }
            }
            completionHandler(.allow)
        case 416:
            completionHandler(.cancel)
            let session = store.sessions[taskID]
            let url = session?.url
            let segments = session?.segments.values.map(\.segment) ?? []
            Task.detached { [weak self] in
                guard let self, let url else { return }
                let probe = await DownloadProbe(url: url).probe()
                let size = probe?.contentLength
                self.store.queue.async { [weak self] in
                    guard let self else { return }
                    if let size, size > 0 {
                        let map = DownloadSegmentMap(segments: segments, totalBytes: size).repairingAfter416(serverSize: size)
                        self.finishSessionOnQueue(taskID: taskID, mode: .failed(message: "", needsAttention: false))
                        self.hopToMain { [weak self] in
                            guard let self else { return }
                            self.delegate?.segmentedCoordinator(self, needsRepair: taskID, segments: map.map.segments, serverSize: size)
                        }
                    } else {
                        self.finishSessionOnQueue(taskID: taskID, mode: .failed(message: "HTTP 416 — file no longer resumable", needsAttention: false))
                    }
                }
            }
        default:
            completionHandler(.cancel)
            segmentFailed(taskID: taskID, segmentID: transfer.segment.segmentID, error: nil, status: status)
        }
    }

    private func revalidateWithServerSize(taskID: UUID, serverSize: Int64) {
        guard let session = store.sessions[taskID] else { return }
        let segments = session.segments.values.map(\.segment)
        let map = DownloadSegmentMap(segments: segments, totalBytes: serverSize).repairingAfter416(serverSize: serverSize)
        store.sessions.removeValue(forKey: taskID)
        store.taskIDByTaskIdentifier = store.taskIDByTaskIdentifier.filter { $0.value != taskID }
        hopToMain { [weak self] in
            guard let self else { return }
            self.delegate?.segmentedCoordinator(self, needsRepair: taskID, segments: map.map.segments, serverSize: serverSize)
        }
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let taskID = store.taskIDByTaskIdentifier[dataTask.taskIdentifier],
              let sessionState = store.sessions[taskID],
              let transfer = sessionState.segments.values.first(where: { $0.dataTask === dataTask }),
              let fileHandle = transfer.fileHandle else {
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finishSessionOnQueue(taskID: taskID, mode: .failed(message: "Segment write failed: \(error.localizedDescription)", needsAttention: false))
            return
        }
        let bytes = Int64(data.count)
        transfer.segment.downloadedBytes += bytes
        transfer.wroteBytes += bytes
        sessionState.monitor.record(bytes: bytes)
        sessionState.throttler.account(bytes: bytes, session: sessionState, coordinator: self)
        reportProgress(for: taskID)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let taskID = store.taskIDByTaskIdentifier[task.taskIdentifier],
              let sessionState = store.sessions[taskID],
              let transfer = sessionState.segments.values.first(where: { $0.dataTask === task }) else {
            return
        }
        transfer.dataTask = nil
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                // Cancelled by pause/discard — handled by those paths.
                return
            }
            segmentFailed(taskID: taskID, segmentID: transfer.segment.segmentID, error: error)
        } else {
            guard transfer.responded206 else {
                segmentFailed(taskID: taskID, segmentID: transfer.segment.segmentID, error: nil)
                return
            }
            let expected = transfer.contentRangeEnd.map { $0 - (transfer.contentRangeStart ?? 0) + 1 } ?? transfer.segment.expectedBytes
            let received = transfer.wroteBytes
            guard received == expected else {
                transfer.segment.state = .failed
                transfer.segment.lastError = "Short transfer: expected \(expected) bytes, received \(received)"
                segmentFailed(taskID: taskID, segmentID: transfer.segment.segmentID, error: nil)
                return
            }
            segmentCompleted(taskID: taskID, segmentID: transfer.segment.segmentID)
        }
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
        // Fail closed: never transparently retry with default credentials
        // inside a segmented transfer.
        completionHandler(.cancelAuthenticationChallenge, nil)
        if let taskID = store.taskIDByTaskIdentifier[task.taskIdentifier] {
            finishSessionOnQueue(taskID: taskID, mode: .failed(message: "Authentication required", needsAttention: true))
        }
    }
}

// MARK: - Bandwidth throttling (segments)

/// Applies the shared `fluxdl_bandwidth_limit` user default to a segmented
/// session: when the session exceeds the limit inside a window, its segment
/// tasks are suspended until the next window. Mirrors the engine's behavior.
fileprivate final class SegmentedThrottleController: @unchecked Sendable {

    private static let window: TimeInterval = 0.5
    private static let limitKey = "fluxdl_bandwidth_limit"

    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private var suspended = false
    private var resumeWork: DispatchWorkItem?

    func account(bytes: Int64, session: SegmentedTransferCoordinator.Session, coordinator: SegmentedTransferCoordinator) {
        let limit = UserDefaults.standard.double(forKey: Self.limitKey)
        let now = Date()
        if now.timeIntervalSince(windowStart) >= Self.window {
            windowStart = now
            windowBytes = 0
            if suspended {
                suspended = false
                resumeAll(in: session)
            }
        }
        guard limit > 0 else {
            if suspended {
                suspended = false
                resumeAll(in: session)
            }
            return
        }
        windowBytes += bytes
        let budget = limit * Self.window
        if Double(windowBytes) > budget && !suspended {
            suspended = true
            suspendAll(in: session)
            let work = DispatchWorkItem { [weak self] in
                self?.windowStart = Date()
                self?.windowBytes = 0
                self?.suspended = false
                self?.resumeAll(in: session)
            }
            resumeWork = work
            coordinator.store.queue.asyncAfter(deadline: .now() + Self.window, execute: work)
        }
    }

    private func suspendAll(in session: SegmentedTransferCoordinator.Session) {
        for transfer in session.segments.values {
            transfer.dataTask?.suspend()
        }
    }

    private func resumeAll(in session: SegmentedTransferCoordinator.Session) {
        for transfer in session.segments.values {
            transfer.dataTask?.resume()
        }
    }
}