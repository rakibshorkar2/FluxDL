import Foundation
import UIKit
import Combine

// MARK: - Protocol

public protocol DownloadEngineProtocol: AnyObject {
    var tasksPublisher: AnyPublisher<[DownloadTaskModel], Never> { get }
    var tasks: [DownloadTaskModel] { get }
    var session: URLSession { get }

    func startDownload(url: URL, filename: String?) -> UUID
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

    // ── O(1) reverse-lookup: URLSessionTask.taskIdentifier → task UUID ──────
    // Touched only from delegate queue – no MainActor annotation needed because
    // it is protected by delegateQueue (serial).
    nonisolated(unsafe) private var taskIDBySessionID: [Int: UUID] = [:]           // delegate queue only
    nonisolated(unsafe) private var progressByID:      [UUID: ProgressSnapshot] = [:] // delegate queue only

    // URLSessionDownloadTask reference (for cancel/pause) – MainActor only
    private var urlTaskByID: [UUID: URLSessionDownloadTask] = [:]

    // Redirect count tracking – MainActor only
    private var redirectCountByID: [UUID: Int] = [:]

    // ── Dependencies ────────────────────────────────────────────────────────
    private let repository:         DownloadRepositoryProtocol
    private let fileManagerService: FileManagementServiceProtocol
    private let hapticService:      HapticServiceProtocol
    private let notificationService:NotificationServiceProtocol

    // Serial queue that URLSession uses for its delegate callbacks
    private let delegateQueue = OperationQueue()

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
    }

    // MARK: ── Public API (all @MainActor) ───────────────────────────────────

    @discardableResult
    public func startDownload(url: URL, filename: String? = nil) -> UUID {
        var model = DownloadTaskModel(url: url, filename: filename, status: .downloading)
        model.startedAt = Date()
        tasks.insert(model, at: 0)

        let dlTask = session.downloadTask(with: url)
        urlTaskByID[model.id] = dlTask

        // Register reverse lookup on delegate queue (serialised)
        let taskID     = model.id
        let sessionKey = dlTask.taskIdentifier
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

        tasks[0].sessionTaskIdentifier = sessionKey
        repository.saveTasks(tasks)
        dlTask.resume()
        hapticService.impactOccurred(.light)
        updateScreenAwakeState()
        notifyKeepAlive()
        return model.id
    }

    public func pauseDownload(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        if let dlTask = urlTaskByID[id] {
            dlTask.cancel { [weak self] resumeData in
                // This closure runs on delegateQueue
                guard let self else { return }
                Task { @MainActor in
                    guard let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
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

        tasks[index].status       = .downloading
        tasks[index].errorMessage = nil
        if tasks[index].startedAt == nil { tasks[index].startedAt = Date() }

        let dlTask: URLSessionDownloadTask
        if let data = model.resumeData {
            dlTask = session.downloadTask(withResumeData: data)
        } else {
            dlTask = session.downloadTask(with: model.activeURL)
        }

        urlTaskByID[id] = dlTask
        tasks[index].sessionTaskIdentifier = dlTask.taskIdentifier

        let taskID     = id
        let sessionKey = dlTask.taskIdentifier
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
        let oldTask = tasks[index]

        // Record this retry attempt in history
        let record = RetryRecord(
            date: Date(),
            errorMessage: oldTask.errorMessage,
            httpStatus: oldTask.lastHTTPStatusCode
        )

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

        let dlTask = session.downloadTask(with: tasks[index].activeURL)
        urlTaskByID[id] = dlTask
        tasks[index].sessionTaskIdentifier = dlTask.taskIdentifier

        let taskID     = id
        let sessionKey = dlTask.taskIdentifier
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
        urlTaskByID[id]?.cancel()
        urlTaskByID.removeValue(forKey: id)
        cleanupDelegateTracking(id: id)
        redirectCountByID.removeValue(forKey: id)

        tasks[index].url                  = newURL
        tasks[index].status               = .paused   // caller can resume after
        tasks[index].resumeData           = nil        // can't resume with new URL
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
        delegateQueue.addOperation { [weak self] in
            self?.taskIDBySessionID[sessionTaskIdentifier] = taskId
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
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            // Remove by value search (only runs on status change, not hot path)
            self.taskIDBySessionID = self.taskIDBySessionID.filter { $0.value != id }
            self.progressByID.removeValue(forKey: id)
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
    private func notifyKeepAlive() {
        let hasActiveDownloads = tasks.contains { $0.status == .downloading }
        let browserKeepAlive  = UserDefaults.standard.bool(forKey: "fluxdl_bg_keepalive_browser")
        ServiceContainer.shared.backgroundKeepAliveService
            .updateKeepAliveState(hasActiveDownloads: hasActiveDownloads,
                                  isBrowserActive: browserKeepAlive)
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
        guard var snap = progressByID[taskIDBySessionID[downloadTask.taskIdentifier] ?? UUID()] else { return }
        guard let id   = taskIDBySessionID[downloadTask.taskIdentifier] else { return }

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

        guard let id = taskIDBySessionID[downloadTask.taskIdentifier] else {
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
                let finalURL = try self.fileManagerService.moveFile(from: copyURL, to: self.tasks[idx].filename)

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

        guard let id = taskIDBySessionID[task.taskIdentifier] else { return }

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

                // Record the failure before retry
                let record = RetryRecord(date: Date(), errorMessage: error.localizedDescription, httpStatus: nil)
                self.tasks[idx].retryHistory.append(record)

                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                self.retryDownload(id: id)
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
        if let id = taskIDBySessionID[task.taskIdentifier] {
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
