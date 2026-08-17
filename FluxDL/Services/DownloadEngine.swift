import Foundation
import UIKit
import Combine

// MARK: - Protocol

public protocol DownloadEngineProtocol: AnyObject {
    var tasksPublisher: AnyPublisher<[DownloadTaskModel], Never> { get }
    var tasks: [DownloadTaskModel] { get }
    var session: URLSession { get }

func startDownload(
        url: URL,
        filename: String?,
        folderGroupID: UUID?,
        relativePath: String?,
        destinationDirectoryPath: String?
    ) -> UUID
    func pauseDownload(id: UUID)
    func resumeDownload(id: UUID)
    func cancelDownload(id: UUID)
    func retryDownload(id: UUID)
    func deleteDownload(id: UUID, deleteFile: Bool)
    func resetToPaused(taskId: UUID) async
    func changePriority(for taskId: UUID, to newPriority: DownloadPriority)
    func moveTask(from sourceIndex: Int, to destinationIndex: Int)
    func updateURL(_ newURL: URL, for id: UUID)
}

// MARK: - Convenience overload (defaults live here, not in the requirement)

public extension DownloadEngineProtocol {
    /// Starts a standalone single-file download. Folder downloads pass the
    /// extra parameters through the full requirement instead.
    @discardableResult
    func startDownload(url: URL, filename: String? = nil) -> UUID {
        startDownload(
            url: url,
            filename: filename,
            folderGroupID: nil,
            relativePath: nil,
            destinationDirectoryPath: nil
        )
    }
}

// MARK: - Internal Progress Snapshot (lives on delegate queue, no actor needed)

private struct ProgressSnapshot {
    var downloadedBytes: Int64
    var totalBytes: Int64
    var lastSpeedSampleBytes: Int64
    var lastSpeedSampleTime: TimeInterval   // CFAbsoluteTimeGetCurrent()
    var lastUIUpdateTime: TimeInterval
    var speedBytesPerSec: Double
    var remainingSeconds: Double
    var totalBytesAccumulated: Double       // for running average speed
    var totalTimeAccumulated: Double
}

// MARK: - Background Session Identifier

private let kBackgroundSessionID = "com.rakib.FluxDL.bg"
private let kUIUpdateInterval: TimeInterval = 0.8  // max one MainActor hop per 0.8 s per task

// MARK: - DownloadEngine

@MainActor
public final class DownloadEngine: NSObject, ObservableObject, DownloadEngineProtocol {

    // ── Published state (MainActor only) ────────────────────────────────────
    @Published public private(set) var tasks: [DownloadTaskModel] = []

    public var tasksPublisher: AnyPublisher<[DownloadTaskModel], Never> {
        $tasks.eraseToAnyPublisher()
    }

    public private(set) var session: URLSession = URLSession(configuration: .default)
    public var backgroundCompletionHandler: (() -> Void)?

    /// Proxy route, injected by `ServiceContainer`. While the proxy is enabled
    /// and the downloads route is on, NEW download tasks are created on a
    /// dedicated proxied (foreground) session. The background session keeps
    /// owning restored tasks so Apple's background-transfer semantics are
    /// never broken.
    public weak var proxyProvider: ProxyProviding?
    private let proxySessionProvider = ProxySessionProvider()
    private var proxiedSession: URLSession?
    /// Fingerprint of the configuration `proxiedSession` was built with.
    /// When the active proxy configuration changes (profile switch/update),
    /// the mismatch invalidates the session so tasks cannot keep routing
    /// through a stale endpoint.
    private var proxiedSessionFingerprint: String?
    /// Fired after the effective routing state changes.
    public var onRoutingStateChange: (() -> Void)?

    // ── O(1) reverse-lookup: URLSessionTask.taskIdentifier → task UUID ──────
    // Touched only from delegate queue – no MainActor annotation needed because
    // it is protected by delegateQueue (serial).
    nonisolated(unsafe) private var taskIDBySessionID: [String: UUID] = [:]       // delegate queue only
    nonisolated(unsafe) private var progressByID:      [UUID: ProgressSnapshot] = [:] // delegate queue only

    // ── Bandwidth throttle (delegate queue only) ─────────────────────────────
    // URLSession has no bandwidth-limit API, so the limit is enforced by
    // suspending a task for the remainder of its 1s window when it exceeds
    // `fluxdl_bandwidth_limit` KB/s, then resuming it. All state below is
    // touched exclusively on `delegateQueue` (serial) — including the
    // deferred resume, which is re-queued onto the same queue.
    private struct ThrottleWindow {
        var windowStart: CFAbsoluteTime
        var windowBytes: Int64
    }
    nonisolated(unsafe) private var throttleWindows:      [UUID: ThrottleWindow] = [:] // delegate queue only
    nonisolated(unsafe) private var throttleLastTotalBytes: [UUID: Int64]       = [:] // delegate queue only

    // URLSessionDownloadTask reference (for cancel/pause) – MainActor only
    private var urlTaskByID: [UUID: URLSessionDownloadTask] = [:]

    // Owning session identity per live task – MainActor only. Lets the engine
    // tell which tasks belong to the proxied session when it is dropped
    // (profile switch/disable) so they can be requeued instead of continuing
    // through a stale proxy configuration.
    private var sessionByTaskID: [UUID: ObjectIdentifier] = [:]

    // Pending auto-retry tasks (MainActor only) — cancelled when the user
    // cancels/pauses/deletes a download during the retry delay.
    private var autoRetryTaskByID: [UUID: Task<Void, Never>] = [:]

    // Redirect count tracking – MainActor only
    private var redirectCountByID: [UUID: Int] = [:]

    // ── Dependencies ────────────────────────────────────────────────────────
    private let repository:         DownloadRepositoryProtocol
    private let fileManagerService: FileManagementServiceProtocol
    private let hapticService:      HapticServiceProtocol
    private let notificationService:NotificationServiceProtocol

    // Serial queue that URLSession uses for its delegate callbacks
    private let delegateQueue = OperationQueue()

    private var cancellables = Set<AnyCancellable>()

    // MARK: init

    public init(
        repository:          DownloadRepositoryProtocol,
        fileManagerService:  FileManagementServiceProtocol,
        hapticService:       HapticServiceProtocol,
        notificationService: NotificationServiceProtocol
    ) {
        self.repository          = repository
        self.fileManagerService  = fileManagerService
        self.hapticService       = hapticService
        self.notificationService = notificationService
        super.init()

        // Single-thread delegate queue – keeps all delegate bookkeeping off MainActor
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility

        let config = URLSessionConfiguration.background(withIdentifier: kBackgroundSessionID)
        config.sessionSendsLaunchEvents          = true
        config.isDiscretionary                   = false
        config.allowsCellularAccess              = true
        config.waitsForConnectivity              = true
        config.httpMaximumConnectionsPerHost     = 4
        config.timeoutIntervalForRequest         = 60
        config.timeoutIntervalForResource        = 0    // no limit on large files

        self.session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.tasks   = repository.loadTasks()

        // The Settings tab writes `fluxdl_screen_awake_minutes` straight to
        // UserDefaults; re-apply Keep Screen Awake immediately when it changes
        // instead of waiting for the next task-status change. Same pattern as
        // BrowserTabManager.handleUserDefaultsChange.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateScreenAwakeState() }
            .store(in: &cancellables)
    }

    // MARK: ── Public API (all @MainActor) ───────────────────────────────────

    /// True when the user explicitly requested the downloads proxy route.
    private var downloadsRouteRequested: Bool {
        proxyProvider?.isEnabled == true && proxyProvider?.downloadsProxyEnabled == true
    }

    /// The proxied route is only usable once the service reports CONNECTED,
    /// an active configuration exists, AND the session provider confirmed it
    /// can apply the proxy (adapter bind failure must never silently produce
    /// a direct session). Any other combination — starting, failed, missing
    /// config — must fail closed: never direct.
    private var isProxiedRouteUsable: Bool {
        guard downloadsRouteRequested else { return false }
        return proxyProvider?.connectionState == .connected
            && proxyProvider?.activeConfiguration != nil
            && proxySessionProvider.lastApplyFailure == nil
    }

    /// Session used for NEW download tasks. While the downloads proxy route
    /// is active, tasks are created on a foreground proxied session through
    /// `ProxySessionProvider` (SOCKS4 inbound traffic is bridged by the local
    /// adapter). Otherwise the background session is used as before.
    ///
    /// Returns nil when the proxy route is requested but not usable: callers
    /// MUST fail closed (never fall back to direct networking).
    private func activeSession() -> URLSession? {
        if downloadsRouteRequested {
            guard proxyProvider?.connectionState == .connected,
                  let configuration = proxyProvider?.activeConfiguration else { return nil }

            let fingerprint = configuration.fingerprint
            if proxiedSession == nil || proxiedSessionFingerprint != fingerprint {
                proxiedSession?.finishTasksAndInvalidate()
                proxiedSession = nil
                proxiedSessionFingerprint = nil
                let config = proxySessionProvider.sessionConfiguration(for: configuration)
                // Confirmed no adapter/native failure: an empty proxy list here
                // would be a silent direct downgrade.
                guard proxySessionProvider.lastApplyFailure == nil else { return nil }
                config.waitsForConnectivity = true
                config.timeoutIntervalForResource = 0
                config.httpMaximumConnectionsPerHost = 4
                proxiedSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
                proxiedSessionFingerprint = fingerprint
            }
            return proxiedSession
        }
        return session
    }

    /// Re-evaluates routing after the proxy state changes. When the proxied
    /// session is dropped (profile switch/update, proxy disabled, route
    /// failure), in-flight tasks on it are REQUIRED to never keep running
    /// through a stale proxy configuration — they are requeued and restarted
    /// on the current route (new proxied session, or the background session
    /// when the route was disabled) by `QueueManager.scheduleNextTasks`.
    /// Consumers (browser) are notified through `onRoutingStateChange`.
    public func refreshProxyRouting() {
        let configuration = proxyProvider?.activeConfiguration
        let isUsable = proxyProvider?.connectionState == .connected
            && (proxyProvider?.isEnabled == true)
            && (proxyProvider?.downloadsProxyEnabled == true)
            && configuration != nil
        if !isUsable || proxiedSessionFingerprint != configuration?.fingerprint {
            if let dropped = proxiedSession {
                proxiedSession = nil
                proxiedSessionFingerprint = nil
                requeueTasks(from: dropped)
                dropped.finishTasksAndInvalidate()
            }
        }
        onRoutingStateChange?()
    }

    /// Moves tasks still attached to a dropped proxied session back to
    /// `.pending`. The URLSession-level task is cancelled with resume data so
    /// the download restarts on the current session (new proxy or direct)
    /// instead of silently continuing through the old configuration.
    private func requeueTasks(from dropped: URLSession) {
        let droppedID = ObjectIdentifier(dropped)
        let affected = urlTaskByID.keys.filter { sessionByTaskID[$0] == droppedID }
        guard !affected.isEmpty else { return }

        for id in affected {
            guard let index = tasks.firstIndex(where: { $0.id == id }),
                  tasks[index].status == .downloading,
                  let dlTask = urlTaskByID[id] else { continue }
            autoRetryTaskByID[id]?.cancel()
            autoRetryTaskByID.removeValue(forKey: id)

            dlTask.cancel { [weak self, capturedTask = dlTask] resumeData in
                // This closure runs on delegateQueue
                guard let self else { return }
                Task { @MainActor in
                    guard let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
                    // Ignore if the task was resumed/deleted/retried or the
                    // session already changed again while the cancel was in
                    // flight — never resurrect a stale requeue over the
                    // current route.
                    guard self.urlTaskByID[id] === capturedTask,
                          self.sessionByTaskID[id] == droppedID else { return }
                    self.tasks[idx].resumeData         = resumeData
                    self.tasks[idx].status             = .pending
                    self.tasks[idx].errorMessage       = nil
                    self.tasks[idx].speedBytesPerSec   = 0
                    self.tasks[idx].remainingTimeSeconds = 0
                    self.tasks[idx].sessionTaskIdentifier = nil
                    self.urlTaskByID.removeValue(forKey: id)
                    self.sessionByTaskID.removeValue(forKey: id)
                    self.cleanupDelegateTracking(id: id)
                    ServiceContainer.shared.liveActivityManager.endActivity(for: id)
                    self.repository.saveTasks(self.tasks)
                    ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
                    self.updateScreenAwakeState()
                    self.notifyKeepAlive()
                }
            }
        }
    }

    /// Stable identity for the task reverse-lookup. Delegate callbacks arrive
    /// with their owning session; when the proxied and background sessions
    /// coexist, their taskIdentifiers can collide, so keys are namespaced by
    /// session identity.
    nonisolated private func lookupKey(for session: URLSession, taskIdentifier: Int) -> String {
        "\(ObjectIdentifier(session).hashValue)-\(taskIdentifier)"
    }

    @discardableResult
    public func startDownload(
        url: URL,
        filename: String? = nil,
        folderGroupID: UUID? = nil,
        relativePath: String? = nil,
        destinationDirectoryPath: String? = nil
    ) -> UUID {
        // Fail-closed proxy routing: when the downloads route is requested
        // but the proxy is not usable (starting, failed, adapter broken),
        // the download FAILS with a proxy error instead of silently starting
        // over a direct connection.
        let proxyBlocked = downloadsRouteRequested && !isProxiedRouteUsable

        // Honor the concurrency settings: at capacity a new task starts as
        // `.pending` and is picked up by `QueueManager.scheduleNextTasks`
        // as soon as an active slot frees up.
        let queueManager = ServiceContainer.shared.queueManager
        let activeCount = tasks.filter { $0.status == .downloading }.count
        let allowed = queueManager.queueMode == .sequential ? 1 : queueManager.maxConcurrentDownloads
        let canStartNow = activeCount < allowed

        var model = DownloadTaskModel(
            url: url,
            filename: filename,
            status: proxyBlocked ? .failed : (canStartNow ? .downloading : .pending)
        )
        model.startedAt = Date()
        model.queuePosition = tasks.count
        model.folderGroupID = folderGroupID
        model.relativePath = relativePath
        model.destinationDirectoryPath = destinationDirectoryPath
        if proxyBlocked {
            model.errorMessage = "Proxy route is not ready (connecting or failed). Downloads require the proxy — no direct fallback."
        }
        tasks.insert(model, at: 0)

        guard !proxyBlocked else {
            repository.saveTasks(tasks)
            return model.id
        }

        guard canStartNow else {
            repository.saveTasks(tasks)
            return model.id
        }

        guard let usedSession = activeSession() else {
            // Defensive: the route became unusable between the check above
            // and the session build (both run on the MainActor, but the
            // adapter can fail inside the build). Fail closed, never crash.
            tasks[0].status = .failed
            tasks[0].errorMessage = "Proxy route is not ready (connecting or failed). Downloads require the proxy — no direct fallback."
            repository.saveTasks(tasks)
            return model.id
        }
        let dlTask = usedSession.downloadTask(with: url)
        urlTaskByID[model.id] = dlTask
        sessionByTaskID[model.id] = ObjectIdentifier(usedSession)

        // Register reverse lookup on delegate queue (serialised)
        let taskID     = model.id
        let sessionKey = lookupKey(for: usedSession, taskIdentifier: dlTask.taskIdentifier)
        delegateQueue.addOperation { [weak self] in
            self?.taskIDBySessionID[sessionKey] = taskID
            self?.progressByID[taskID] = ProgressSnapshot(
                downloadedBytes: 0, totalBytes: 0,
                lastSpeedSampleBytes: 0,
                lastSpeedSampleTime: CFAbsoluteTimeGetCurrent(),
                lastUIUpdateTime: 0,
                speedBytesPerSec: 0, remainingSeconds: 0,
                totalBytesAccumulated: 0, totalTimeAccumulated: 0
            )
        }

        tasks[0].sessionTaskIdentifier = dlTask.taskIdentifier
        repository.saveTasks(tasks)
        dlTask.resume()
        hapticService.impactOccurred(.light)
        updateScreenAwakeState()
        notifyKeepAlive()
        return model.id
    }

    public func pauseDownload(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        autoRetryTaskByID[id]?.cancel()
        autoRetryTaskByID.removeValue(forKey: id)

        if let dlTask = urlTaskByID[id] {
            dlTask.cancel { [weak self, capturedTask = dlTask] resumeData in
                // This closure runs on delegateQueue
                guard let self else { return }
                Task { @MainActor in
                    guard let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
                    // If the task was resumed/deleted/retried while the cancel
                    // was in flight, the URLSessionDownloadTask is no longer
                    // the current one — applying this completion would
                    // resurrect a stale pause over a running download.
                    guard self.urlTaskByID[id] === capturedTask else { return }
                    self.tasks[idx].resumeData         = resumeData
                    self.tasks[idx].status             = .paused
                    self.tasks[idx].speedBytesPerSec   = 0
                    self.tasks[idx].remainingTimeSeconds = 0
                    self.tasks[idx].sessionTaskIdentifier = nil
                    self.urlTaskByID.removeValue(forKey: id)
                    self.repository.saveTasks(self.tasks)
                    self.hapticService.impactOccurred(.medium)
                    self.cleanupDelegateTracking(id: id)
                    ServiceContainer.shared.liveActivityManager.endActivity(for: id)
                    ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
                    self.updateScreenAwakeState()
                    self.notifyKeepAlive()
                }
            }
        } else {
            tasks[index].status              = .paused
            tasks[index].speedBytesPerSec    = 0
            tasks[index].remainingTimeSeconds = 0
            tasks[index].sessionTaskIdentifier = nil
            repository.saveTasks(tasks)
            cleanupDelegateTracking(id: id)
            ServiceContainer.shared.liveActivityManager.endActivity(for: id)
            ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
            updateScreenAwakeState()
            notifyKeepAlive()
        }
    }

    public func resumeDownload(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let model = tasks[index]

        // Fail-closed: a download whose route is requested must never resume
        // over a direct connection. It stays paused/pending and starts as
        // soon as the proxy route becomes usable again (routing state change
        // triggers `scheduleNextTasks`).
        if downloadsRouteRequested && !isProxiedRouteUsable { return }

        guard let usedSession = activeSession() else { return }

        tasks[index].status       = .downloading
        tasks[index].errorMessage = nil
        if tasks[index].startedAt == nil { tasks[index].startedAt = Date() }

        let dlTask: URLSessionDownloadTask
        if let data = model.resumeData {
            dlTask = usedSession.downloadTask(withResumeData: data)
        } else {
            dlTask = usedSession.downloadTask(with: model.activeURL)
        }

        urlTaskByID[id] = dlTask
        sessionByTaskID[id] = ObjectIdentifier(usedSession)
        tasks[index].sessionTaskIdentifier = dlTask.taskIdentifier

        let taskID     = id
        let sessionKey = lookupKey(for: usedSession, taskIdentifier: dlTask.taskIdentifier)
        let startBytes = model.downloadedBytes
        delegateQueue.addOperation { [weak self] in
            self?.taskIDBySessionID[sessionKey] = taskID
            self?.progressByID[taskID] = ProgressSnapshot(
                downloadedBytes: startBytes, totalBytes: model.totalBytes,
                lastSpeedSampleBytes: startBytes,
                lastSpeedSampleTime: CFAbsoluteTimeGetCurrent(),
                lastUIUpdateTime: 0,
                speedBytesPerSec: 0, remainingSeconds: 0,
                totalBytesAccumulated: 0, totalTimeAccumulated: 0
            )
        }

        dlTask.resume()
        repository.saveTasks(tasks)
        hapticService.impactOccurred(.light)
        updateScreenAwakeState()
        notifyKeepAlive()
    }

    public func cancelDownload(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        autoRetryTaskByID[id]?.cancel()
        autoRetryTaskByID.removeValue(forKey: id)
        urlTaskByID[id]?.cancel()
        urlTaskByID.removeValue(forKey: id)
        cleanupDelegateTracking(id: id)
        redirectCountByID.removeValue(forKey: id)

        tasks[index].status               = .cancelled
        tasks[index].speedBytesPerSec     = 0
        tasks[index].remainingTimeSeconds  = 0
        tasks[index].sessionTaskIdentifier = nil
        repository.saveTasks(tasks)
        hapticService.notificationOccurred(.warning)
        ServiceContainer.shared.liveActivityManager.endActivity(for: id)
        ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
        updateScreenAwakeState()
        notifyKeepAlive()
    }

    public func retryDownload(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        // Fail-closed: automatic and manual retries must never go direct
        // while the proxy route is requested but unusable — including the
        // auto-retry path fired right after a proxy-caused failure.
        if downloadsRouteRequested && !isProxiedRouteUsable { return }

        guard let usedSession = activeSession() else { return }

        let oldTask = tasks[index]

        // Record this retry attempt in history
        let record = RetryRecord(
            date: Date(),
            errorMessage: oldTask.errorMessage,
            httpStatus: oldTask.lastHTTPStatusCode
        )

        autoRetryTaskByID[id]?.cancel()
        autoRetryTaskByID.removeValue(forKey: id)
        urlTaskByID[id]?.cancel()
        urlTaskByID.removeValue(forKey: id)
        cleanupDelegateTracking(id: id)
        redirectCountByID.removeValue(forKey: id)

        tasks[index].status               = .downloading
        tasks[index].downloadedBytes      = 0
        tasks[index].resumeData           = nil
        tasks[index].errorMessage         = nil
        tasks[index].retryCount          += 1
        tasks[index].retryHistory.append(record)
        if tasks[index].startedAt == nil { tasks[index].startedAt = Date() }

        let dlTask = usedSession.downloadTask(with: tasks[index].activeURL)
        urlTaskByID[id] = dlTask
        tasks[index].sessionTaskIdentifier = dlTask.taskIdentifier

        let taskID     = id
        let sessionKey = lookupKey(for: usedSession, taskIdentifier: dlTask.taskIdentifier)
        delegateQueue.addOperation { [weak self] in
            self?.taskIDBySessionID[sessionKey] = taskID
            self?.progressByID[taskID] = ProgressSnapshot(
                downloadedBytes: 0, totalBytes: 0,
                lastSpeedSampleBytes: 0,
                lastSpeedSampleTime: CFAbsoluteTimeGetCurrent(),
                lastUIUpdateTime: 0,
                speedBytesPerSec: 0, remainingSeconds: 0,
                totalBytesAccumulated: 0, totalTimeAccumulated: 0
            )
        }

        dlTask.resume()
        repository.saveTasks(tasks)
        hapticService.impactOccurred(.medium)
        updateScreenAwakeState()
        notifyKeepAlive()
    }

    /// Update the download URL for a paused or failed task.
    /// Preserves: filename, destination, createdAt, mirrors, tags, metadata.
    /// Clears: resumeData (clean restart), errorMessage, lastHTTPStatusCode.
    public func updateURL(_ newURL: URL, for id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        // Cancel any active session task
        autoRetryTaskByID[id]?.cancel()
        autoRetryTaskByID.removeValue(forKey: id)
        urlTaskByID[id]?.cancel()
        urlTaskByID.removeValue(forKey: id)
        cleanupDelegateTracking(id: id)
        redirectCountByID.removeValue(forKey: id)

        tasks[index].url                  = newURL
        tasks[index].status               = .paused   // caller can resume after
        tasks[index].resumeData           = nil        // can't resume with new URL
        tasks[index].downloadedBytes      = 0          // bytes belong to the old URL
        tasks[index].totalBytes           = 0
        tasks[index].currentMirrorIndex   = 0          // mirrors belong to the old URL
        tasks[index].errorMessage         = nil
        tasks[index].lastHTTPStatusCode   = nil
        tasks[index].speedBytesPerSec     = 0
        tasks[index].remainingTimeSeconds = 0
        tasks[index].sessionTaskIdentifier = nil

        repository.saveTasks(tasks)
        hapticService.impactOccurred(.medium)
    }

    /// Apply an in-place mutation to a task and persist the result.
    /// Returns `false` if no task with the given id exists.
    @discardableResult
    public func mutateTask(id: UUID, _ transform: (inout DownloadTaskModel) -> Void) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        transform(&tasks[index])
        repository.saveTasks(tasks)
        return true
    }

    public func changePriority(for taskId: UUID, to newPriority: DownloadPriority) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].priority = newPriority
        repository.saveTasks(tasks)
    }

    public func moveTask(from sourceIndex: Int, to destinationIndex: Int) {
        var active = tasks.filter { $0.status != .completed }
        guard (0..<active.count).contains(sourceIndex),
              (0..<active.count).contains(destinationIndex) else { return }
        let moved = active.remove(at: sourceIndex)
        active.insert(moved, at: destinationIndex)
        for (i, t) in active.enumerated() {
            if let mi = tasks.firstIndex(where: { $0.id == t.id }) {
                tasks[mi].queuePosition = i
            }
        }
        repository.saveTasks(tasks)
    }

    public func deleteDownload(id: UUID, deleteFile: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let model = tasks[index]
        autoRetryTaskByID[id]?.cancel()
        autoRetryTaskByID.removeValue(forKey: id)
        urlTaskByID[id]?.cancel()
        urlTaskByID.removeValue(forKey: id)
        cleanupDelegateTracking(id: id)
        redirectCountByID.removeValue(forKey: id)
        DownloadMirrorManager.shared.removeTask(id)

        if deleteFile, let path = model.destinationPath {
            try? fileManagerService.deleteFile(at: URL(fileURLWithPath: path))
        }

        tasks.remove(at: index)
        repository.saveTasks(tasks)
        hapticService.notificationOccurred(.error)
        ServiceContainer.shared.liveActivityManager.endActivity(for: id)
        ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
        updateScreenAwakeState()
        notifyKeepAlive()
    }

    public func resetToPaused(taskId: UUID) async {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[idx].status               = .paused
        tasks[idx].speedBytesPerSec     = 0
        tasks[idx].remainingTimeSeconds  = 0
        tasks[idx].sessionTaskIdentifier = nil
        repository.saveTasks(tasks)
    }

    /// Called by `DownloadRestorationService` when a live background task is matched
    /// to a persisted record. Re-populates `taskIDBySessionID` and `progressByID` on
    /// the delegate queue so that subsequent `didFinishDownloadingTo` / `didWriteData`
    /// callbacks are properly routed to the correct task model.
    public func reregisterRestoredTask(taskId: UUID, sessionTaskIdentifier: Int, startBytes: Int64, totalBytes: Int64) {
        // Restored tasks always come from the background session (`session`).
        let key = lookupKey(for: session, taskIdentifier: sessionTaskIdentifier)
        delegateQueue.addOperation { [weak self] in
            self?.taskIDBySessionID[key] = taskId
            self?.progressByID[taskId] = ProgressSnapshot(
                downloadedBytes: startBytes,
                totalBytes: totalBytes,
                lastSpeedSampleBytes: startBytes,
                lastSpeedSampleTime: CFAbsoluteTimeGetCurrent(),
                lastUIUpdateTime: 0,
                speedBytesPerSec: 0,
                remainingSeconds: 0,
                totalBytesAccumulated: 0,
                totalTimeAccumulated: 0
            )
        }
    }

    // MARK: ── Private helpers ───────────────────────────────────────────────

    /// Must be called from MainActor; schedules cleanup on delegate queue.
    private func cleanupDelegateTracking(id: UUID) {
        sessionByTaskID.removeValue(forKey: id)
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            // Remove by value search (only runs on status change, not hot path)
            self.taskIDBySessionID = self.taskIDBySessionID.filter { $0.value != id }
            self.progressByID.removeValue(forKey: id)
            self.throttleWindows.removeValue(forKey: id)
            self.throttleLastTotalBytes.removeValue(forKey: id)
        }
    }

    // Track an optional timed wake-lock so we can cancel it when downloads stop.
    private var screenAwakeTimer: DispatchWorkItem?

    private func updateScreenAwakeState() {
        // fluxdl_screen_awake_minutes:
        //   0   = Off
        //  -1   = While downloading (stays on until no active tasks)
        //   N>0 = Enable for N minutes then auto-restore
        let minutes  = UserDefaults.standard.integer(forKey: "fluxdl_screen_awake_minutes")
        let hasDownloading = tasks.contains { $0.status == .downloading }

        // Cancel any pending auto-off timer
        screenAwakeTimer?.cancel()
        screenAwakeTimer = nil

        switch minutes {
        case 0:
            UIApplication.shared.isIdleTimerDisabled = false

        case -1:
            // Permanent while downloading
            UIApplication.shared.isIdleTimerDisabled = hasDownloading

        case let n where n > 0:
            if hasDownloading {
                UIApplication.shared.isIdleTimerDisabled = true
                let workItem = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        UIApplication.shared.isIdleTimerDisabled = false
                        self?.screenAwakeTimer = nil
                    }
                }
                screenAwakeTimer = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .seconds(n * 60),
                    execute: workItem
                )
            } else {
                UIApplication.shared.isIdleTimerDisabled = false
            }

        default:
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Tell BackgroundKeepAliveService whether any task is actively downloading.
    /// Only the downloads slot belongs here — the service keeps the browser and
    /// torrents slots untouched, so a download tick can never cancel another
    /// subsystem's background keep-alive.
    private func notifyKeepAlive() {
        let hasActiveDownloads = tasks.contains { $0.status == .downloading }
        ServiceContainer.shared.backgroundKeepAliveService
            .updateDownloadsKeepAlive(hasActiveDownloads)
    }

    /// Push a throttled UI snapshot from delegate queue → MainActor.
    /// Called only from delegate queue (already serialised).
    nonisolated private func pushUIUpdate(id: UUID, snap: ProgressSnapshot) {
        Task { @MainActor [weak self] in
            guard let self,
                  let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            self.tasks[idx].downloadedBytes          = snap.downloadedBytes
            self.tasks[idx].totalBytes               = snap.totalBytes
            self.tasks[idx].speedBytesPerSec         = snap.speedBytesPerSec
            self.tasks[idx].remainingTimeSeconds      = snap.remainingSeconds
            // Update average speed if we have accumulated data
            if snap.totalTimeAccumulated > 1.0 {
                self.tasks[idx].averageSpeedBytesPerSec = snap.totalBytesAccumulated / snap.totalTimeAccumulated
            }
            // Keep the Dynamic Island / Lock Screen activity live while the
            // app is backgrounded (updateActivity self-throttles to 1 Hz and
            // self-ends for non-downloading states).
            ServiceContainer.shared.liveActivityManager.updateActivity(for: self.tasks[idx])
        }
    }

    /// Apply captured metadata to the task model on the MainActor.
    nonisolated private func applyMetadata(_ meta: CapturedMetadata, to id: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            self.tasks[idx].lastHTTPStatusCode = meta.httpStatusCode
            self.tasks[idx].acceptsRanges      = meta.acceptsRanges
            self.tasks[idx].etag               = meta.etag ?? self.tasks[idx].etag
            self.tasks[idx].lastModified       = meta.lastModified ?? self.tasks[idx].lastModified
            self.tasks[idx].mimeType           = meta.mimeType ?? self.tasks[idx].mimeType
            self.tasks[idx].serverName         = meta.serverName ?? self.tasks[idx].serverName
            self.tasks[idx].responseHeaders    = meta.responseHeaders
        }
    }
}

// MARK: - URLSessionDownloadDelegate (runs on delegateQueue — NOT MainActor)

extension DownloadEngine: URLSessionDownloadDelegate {

    // Called thousands of times per second during a fast download.
    // Everything here runs on delegateQueue (serial, background).
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // O(1) lookup – no MainActor needed
        let hitKey = lookupKey(for: session, taskIdentifier: downloadTask.taskIdentifier)
        guard var snap = progressByID[taskIDBySessionID[hitKey] ?? UUID()] else { return }
        guard let id   = taskIDBySessionID[hitKey] else { return }

        snap.downloadedBytes = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { snap.totalBytes = totalBytesExpectedToWrite }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsedSinceLastUI = now - snap.lastUIUpdateTime

        // Speed sample every 0.5 s
        let elapsedSinceSample = now - snap.lastSpeedSampleTime
        if elapsedSinceSample >= 0.5 {
            let bytesDiff = totalBytesWritten - snap.lastSpeedSampleBytes
            let speed     = Double(bytesDiff) / elapsedSinceSample
            snap.speedBytesPerSec    = max(speed, 0)
            snap.remainingSeconds    = speed > 0 && snap.totalBytes > totalBytesWritten
                ? Double(snap.totalBytes - totalBytesWritten) / speed : 0
            snap.lastSpeedSampleBytes = totalBytesWritten
            snap.lastSpeedSampleTime  = now

            // Accumulate for average speed calculation
            if speed > 0 {
                snap.totalBytesAccumulated += Double(bytesDiff)
                snap.totalTimeAccumulated  += elapsedSinceSample
            }
        }

        progressByID[id] = snap

        // ── Optional bandwidth limit (Settings → Speed) ────────────────────
        // 0 / missing = unlimited. Otherwise hold the task to ~limit KB/s by
        // suspending it for the remainder of the current 1s window. The
        // deferred resume runs on the delegate queue, so all throttle state
        // stays serialised and lock-free.
        let limitKBps = UserDefaults.standard.integer(forKey: "fluxdl_bandwidth_limit")
        if limitKBps > 0 {
            let now       = CFAbsoluteTimeGetCurrent()
            let limitBytes = Int64(limitKBps) * 1024

            let previousTotal = throttleLastTotalBytes[id] ?? totalBytesWritten
            let delta         = totalBytesWritten - previousTotal
            throttleLastTotalBytes[id] = totalBytesWritten

            let window = throttleWindows[id] ?? ThrottleWindow(windowStart: now, windowBytes: 0)
            let start  = now - window.windowStart >= 1.0 ? now : window.windowStart
            let bytes  = now - window.windowStart >= 1.0 ? delta : window.windowBytes + delta
            throttleWindows[id] = ThrottleWindow(windowStart: start, windowBytes: bytes)

            if bytes >= limitBytes {
                downloadTask.suspend()
                let resumeIn = max(0.0, 1.0 - (now - start))
                delegateQueue.addOperation { [weak self] in
                    guard let self else { return }
                    // Account for anything the server pushed while suspended,
                    // then release the task. No-op if it was cancelled first.
                    self.throttleLastTotalBytes[id] = downloadTask.countOfBytesReceived
                    self.throttleWindows.removeValue(forKey: id)
                    downloadTask.resume()
                }
            }
        }

        // Throttle MainActor dispatch to once per kUIUpdateInterval
        guard elapsedSinceLastUI >= kUIUpdateInterval else { return }
        progressByID[id]!.lastUIUpdateTime = now

        let snapCopy = snap
        pushUIUpdate(id: id, snap: snapCopy)
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy temp file immediately (system deletes `location` after this callback returns)
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: copyURL)
        } catch {
            print("FluxDL: failed to copy temp file – \(error)")
            return
        }

        guard let id = taskIDBySessionID[lookupKey(for: session, taskIdentifier: downloadTask.taskIdentifier)] else {
            try? FileManager.default.removeItem(at: copyURL)
            return
        }

        // Capture metadata from the response
        let meta = DownloadMetadataCapture.capture(from: downloadTask.response)

        // ── Reject non-2xx HTTP responses ────────────────────────────────────
        if let httpResp = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResp.statusCode) {
            let code = httpResp.statusCode
            print("FluxDL: HTTP \(code) — rejecting as failed for task \(id).")
            try? FileManager.default.removeItem(at: copyURL)
            Task { @MainActor [weak self] in
                guard let self, let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }

                // Apply metadata before failing
                if let m = meta { self.applyMetadata(m, to: id) }

                self.tasks[idx].status               = .failed
                self.tasks[idx].errorMessage         = "HTTP error \(code). Tap retry."
                self.tasks[idx].lastHTTPStatusCode   = code
                self.tasks[idx].speedBytesPerSec     = 0
                self.tasks[idx].remainingTimeSeconds  = 0
                self.tasks[idx].sessionTaskIdentifier = nil
                self.urlTaskByID.removeValue(forKey: id)
                self.cleanupDelegateTracking(id: id)
                self.repository.saveTasks(self.tasks)
                self.hapticService.notificationOccurred(.error)
                self.notificationService.notifyDownloadFailed(
                    filename: self.tasks[idx].filename, reason: "HTTP error \(code)")
                ServiceContainer.shared.liveActivityManager.endActivity(for: id)

                // Mirror auto-switch on 4xx/5xx
                let shouldSwitch = [401, 403, 404, 410, 429].contains(code) || code >= 500
                if shouldSwitch {
                    let switched = DownloadMirrorManager.shared.recordFailure(for: id, engine: self)
                    if switched { return }  // mirror switched, retry initiated
                }

                ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
                self.updateScreenAwakeState()
                self.notifyKeepAlive()
            }
            return
        }

        // ── CRITICAL: Verify downloaded file has actual content ──────────────
        let copiedFileSize = (try? FileManager.default
            .attributesOfItem(atPath: copyURL.path)[.size] as? Int64) ?? 0
        guard copiedFileSize > 0 else {
            print("FluxDL: Rejecting 0-byte completion for task \(id) – stale session replay or empty server response.")
            try? FileManager.default.removeItem(at: copyURL)
            Task { @MainActor [weak self] in
                guard let self,
                      let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
                self.tasks[idx].status               = .failed
                self.tasks[idx].errorMessage         = "Server returned empty file. Please retry."
                self.tasks[idx].speedBytesPerSec     = 0
                self.tasks[idx].remainingTimeSeconds  = 0
                self.tasks[idx].sessionTaskIdentifier = nil
                self.urlTaskByID.removeValue(forKey: id)
                self.cleanupDelegateTracking(id: id)
                self.repository.saveTasks(self.tasks)
                self.hapticService.notificationOccurred(.error)
                self.notificationService.notifyDownloadFailed(
                    filename: self.tasks[idx].filename,
                    reason: "Server returned empty file")
                ServiceContainer.shared.liveActivityManager.endActivity(for: id)
                ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
                self.updateScreenAwakeState()
                self.notifyKeepAlive()
            }
            return
        }

        // Extract filename from Content-Disposition response header if available
        var headerFilename: String? = nil
        if let httpResp = downloadTask.response as? HTTPURLResponse {
            for key in ["Content-Disposition", "content-disposition"] {
                if let val = httpResp.allHeaderFields[key] as? String,
                   let name = URLFilenameExtractor.extractFilename(fromContentDisposition: val),
                   !name.isEmpty {
                    headerFilename = name
                    break
                }
            }
        }

        // Capture redirect count from delegate tracking
        let capturedMeta = meta

        Task { @MainActor [weak self] in
            guard let self,
                  let idx = self.tasks.firstIndex(where: { $0.id == id }) else {
                try? FileManager.default.removeItem(at: copyURL)
                return
            }

            // Apply metadata
            if let m = capturedMeta {
                self.tasks[idx].lastHTTPStatusCode = m.httpStatusCode
                self.tasks[idx].acceptsRanges      = m.acceptsRanges
                self.tasks[idx].etag               = m.etag ?? self.tasks[idx].etag
                self.tasks[idx].lastModified       = m.lastModified ?? self.tasks[idx].lastModified
                self.tasks[idx].mimeType           = m.mimeType ?? self.tasks[idx].mimeType
                self.tasks[idx].serverName         = m.serverName ?? self.tasks[idx].serverName
                self.tasks[idx].responseHeaders    = m.responseHeaders
            }

            // Update redirect count
            self.tasks[idx].redirectCount = self.redirectCountByID[id] ?? 0
            self.redirectCountByID.removeValue(forKey: id)

            // Update filename from response header if we got a better one
            if let hf = headerFilename, hf != self.tasks[idx].filename {
                self.tasks[idx].filename = hf
            }

            do {
                let finalURL: URL
                if let folderPath = self.tasks[idx].destinationDirectoryPath,
                   let relative = self.tasks[idx].relativePath {
                    finalURL = try self.fileManagerService.moveFile(
                        from: copyURL,
                        toRelativePath: relative,
                        inDirectory: URL(fileURLWithPath: folderPath, isDirectory: true)
                    )
                } else {
                    finalURL = try self.fileManagerService.moveFile(from: copyURL, to: self.tasks[idx].filename)
                }

                let realFileSize = (try? FileManager.default
                    .attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? copiedFileSize

                self.tasks[idx].status              = .completed
                self.tasks[idx].destinationPath     = finalURL.path
                self.tasks[idx].downloadedBytes     = realFileSize
                self.tasks[idx].totalBytes          = realFileSize
                self.tasks[idx].speedBytesPerSec    = 0
                self.tasks[idx].remainingTimeSeconds = 0
                self.tasks[idx].completedAt         = Date()
                self.tasks[idx].sessionTaskIdentifier = nil
                self.urlTaskByID.removeValue(forKey: id)
                self.cleanupDelegateTracking(id: id)
                self.repository.saveTasks(self.tasks)

                self.hapticService.notificationOccurred(.success)
                self.notificationService.notifyDownloadCompleted(filename: self.tasks[idx].filename)
                ServiceContainer.shared.liveActivityManager.endActivity(for: id)
                DownloadMirrorManager.shared.recordSuccess(for: id)
                ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
                self.updateScreenAwakeState()
                self.notifyKeepAlive()

                // Kick off background checksum computation
                let taskSnapshot = self.tasks[idx]
                Task.detached(priority: .utility) {
                    await DownloadVerificationService.shared.computeAndStore(task: taskSnapshot, engine: self)
                }
            } catch {
                self.tasks[idx].status              = .failed
                self.tasks[idx].errorMessage        = "Save failed: \(error.localizedDescription)"
                self.tasks[idx].speedBytesPerSec    = 0
                self.tasks[idx].remainingTimeSeconds = 0
                self.tasks[idx].sessionTaskIdentifier = nil
                self.urlTaskByID.removeValue(forKey: id)
                self.cleanupDelegateTracking(id: id)
                self.repository.saveTasks(self.tasks)

                self.hapticService.notificationOccurred(.error)
                self.notificationService.notifyDownloadFailed(filename: self.tasks[idx].filename,
                                                              reason: error.localizedDescription)
                ServiceContainer.shared.liveActivityManager.endActivity(for: id)
                ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
                self.updateScreenAwakeState()
                self.notifyKeepAlive()
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsErr = error as NSError
        // Ignore user-initiated cancels
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }

        guard let id = taskIDBySessionID[lookupKey(for: session, taskIdentifier: task.taskIdentifier)] else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }

            // Configurable auto-retry check
            let qm = ServiceContainer.shared.queueManager
            let maxRetries = UserDefaults.standard.object(forKey: "fluxdl_max_retry_count") != nil
                ? UserDefaults.standard.integer(forKey: "fluxdl_max_retry_count") : self.tasks[idx].maxRetries
            let retryDelay = UserDefaults.standard.integer(forKey: "fluxdl_retry_delay_seconds")
            let delaySeconds = retryDelay > 0 ? Double(retryDelay) : 5.0

            if qm.autoRetryEnabled && self.tasks[idx].retryCount < maxRetries {
                print("FluxDL: Auto-retrying task \(self.tasks[idx].id) in \(delaySeconds) seconds...")

                let taskID = id
                // Record the failure before retry (single record — the retry
                // itself appends its own history entry).
                self.tasks[idx].errorMessage = error.localizedDescription

                let retryTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    } catch {
                        return // cancelled during the delay — never resurrect
                    }
                    guard !Task.isCancelled else { return }
                    self.autoRetryTaskByID.removeValue(forKey: taskID)
                    self.retryDownload(id: taskID)
                }
                self.autoRetryTaskByID[taskID] = retryTask
                return
            }

            self.tasks[idx].status              = .failed
            self.tasks[idx].errorMessage        = error.localizedDescription
            self.tasks[idx].speedBytesPerSec    = 0
            self.tasks[idx].remainingTimeSeconds = 0
            self.tasks[idx].sessionTaskIdentifier = nil
            self.urlTaskByID.removeValue(forKey: id)
            self.cleanupDelegateTracking(id: id)
            self.repository.saveTasks(self.tasks)

            self.hapticService.notificationOccurred(.error)
            self.notificationService.notifyDownloadFailed(filename: self.tasks[idx].filename,
                                                          reason: error.localizedDescription)
            ServiceContainer.shared.liveActivityManager.endActivity(for: id)

            // Try mirror auto-switch on network failures
            DownloadMirrorManager.shared.recordFailure(for: id, engine: self)

            ServiceContainer.shared.queueManager.scheduleNextTasks(in: self)
            self.updateScreenAwakeState()
            self.notifyKeepAlive()
        }
    }

    // Track HTTP redirects to populate redirectCount metadata.
    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let id = taskIDBySessionID[lookupKey(for: session, taskIdentifier: task.taskIdentifier)] {
            Task { @MainActor [weak self] in
                self?.redirectCountByID[id, default: 0] += 1
            }
        }
        completionHandler(request)
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
