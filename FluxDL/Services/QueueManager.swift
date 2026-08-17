import Foundation
import Combine

public enum QueueMode: String, Codable, CaseIterable, Identifiable {
    case parallel = "Parallel"
    case sequential = "Sequential"
    
    public var id: String { rawValue }
}

@MainActor
public protocol QueueManagerProtocol: AnyObject {
    var maxConcurrentDownloads: Int { get set }
    var queueMode: QueueMode { get set }
    var autoRetryEnabled: Bool { get set }
    var duplicateDetectionEnabled: Bool { get set }
    
    func scheduleNextTasks(in engine: DownloadEngineProtocol)
    func changePriority(for taskId: UUID, to newPriority: DownloadPriority, in engine: DownloadEngineProtocol)
    func moveTask(from sourceIndex: Int, to destinationIndex: Int, in engine: DownloadEngineProtocol)
    func isDuplicate(url: URL, in engine: DownloadEngineProtocol) -> Bool
}

@MainActor
public final class QueueManager: ObservableObject, QueueManagerProtocol {
    private let maxConcurrentKey = "fluxdl_max_concurrent_downloads"
    private let queueModeKey = "fluxdl_queue_mode"
    private let autoRetryKey = "fluxdl_auto_retry_enabled"
    private let duplicateKey = "fluxdl_duplicate_detection_enabled"
    
    @Published public var maxConcurrentDownloads: Int {
        didSet { UserDefaults.standard.set(maxConcurrentDownloads, forKey: maxConcurrentKey) }
    }
    
    @Published public var queueMode: QueueMode {
        didSet { UserDefaults.standard.set(queueMode.rawValue, forKey: queueModeKey) }
    }
    
    @Published public var autoRetryEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRetryEnabled, forKey: autoRetryKey) }
    }
    
    @Published public var duplicateDetectionEnabled: Bool {
        didSet { UserDefaults.standard.set(duplicateDetectionEnabled, forKey: duplicateKey) }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        let storedMax = UserDefaults.standard.integer(forKey: maxConcurrentKey)
        self.maxConcurrentDownloads = storedMax > 0 ? storedMax : 3
        
        if let storedMode = UserDefaults.standard.string(forKey: queueModeKey),
           let mode = QueueMode(rawValue: storedMode) {
            self.queueMode = mode
        } else {
            self.queueMode = .parallel
        }
        
        self.autoRetryEnabled = UserDefaults.standard.object(forKey: autoRetryKey) != nil ? UserDefaults.standard.bool(forKey: autoRetryKey) : true
        self.duplicateDetectionEnabled = UserDefaults.standard.object(forKey: duplicateKey) != nil ? UserDefaults.standard.bool(forKey: duplicateKey) : true

        // Settings toggles are plain UserDefaults keys; react to any change so
        // the concurrency/retry values follow the Settings tab without restart.
        // (Same pattern as BrowserTabManager.handleUserDefaultsChange.)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleUserDefaultsChange() }
            .store(in: &cancellables)
    }
    
    /// Re-syncs values written directly to UserDefaults (e.g. by the Settings
    /// tab's @AppStorage toggles) into the live in-memory properties the
    /// engine actually reads. Equality guards prevent feedback loops, since
    /// each property's didSet writes the same key back.
    func handleUserDefaultsChange() {
        let storedMax = UserDefaults.standard.integer(forKey: maxConcurrentKey)
        let syncedMax = storedMax > 0 ? storedMax : 3
        if syncedMax != maxConcurrentDownloads {
            maxConcurrentDownloads = syncedMax
            // A raised cap should start waiting tasks immediately.
            scheduleNextTasks(in: ServiceContainer.shared.downloadEngine)
        }

        let storedRetry = UserDefaults.standard.object(forKey: autoRetryKey) != nil
            ? UserDefaults.standard.bool(forKey: autoRetryKey) : true
        if storedRetry != autoRetryEnabled {
            autoRetryEnabled = storedRetry
        }
    }

    
    public func scheduleNextTasks(in engine: DownloadEngineProtocol) {
        guard let downloadEngine = engine as? DownloadEngine else { return }
        let currentTasks = downloadEngine.tasks
        
        let currentlyDownloadingCount = currentTasks.filter { $0.status == .downloading }.count
        let allowedConcurrent = queueMode == .sequential ? 1 : maxConcurrentDownloads
        let slotsAvailable = allowedConcurrent - currentlyDownloadingCount
        
        guard slotsAvailable > 0 else { return }
        
        // Find pending tasks sorted by Priority (High -> Normal -> Low) then Queue Position
        let pendingTasks = currentTasks
            .filter { $0.status == .pending }
            .sorted { (t1, t2) -> Bool in
                if t1.priority != t2.priority {
                    return t1.priority > t2.priority
                }
                return t1.queuePosition < t2.queuePosition
            }
        
        for i in 0..<min(slotsAvailable, pendingTasks.count) {
            downloadEngine.resumeDownload(id: pendingTasks[i].id)
        }
    }
    
    public func changePriority(for taskId: UUID, to newPriority: DownloadPriority, in engine: DownloadEngineProtocol) {
        guard let downloadEngine = engine as? DownloadEngine else { return }
        downloadEngine.changePriority(for: taskId, to: newPriority)
        scheduleNextTasks(in: engine)
    }
    
    public func moveTask(from sourceIndex: Int, to destinationIndex: Int, in engine: DownloadEngineProtocol) {
        guard let downloadEngine = engine as? DownloadEngine else { return }
        downloadEngine.moveTask(from: sourceIndex, to: destinationIndex)
        scheduleNextTasks(in: engine)
    }
    
    public func isDuplicate(url: URL, in engine: DownloadEngineProtocol) -> Bool {
        guard duplicateDetectionEnabled else { return false }
        let cleanURLString = url.absoluteString.lowercased()
        return engine.tasks.contains { $0.url.absoluteString.lowercased() == cleanURLString && $0.status != .failed && $0.status != .cancelled }
    }
}
