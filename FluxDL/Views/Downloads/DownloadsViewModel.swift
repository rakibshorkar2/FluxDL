import Foundation
import Combine
import UIKit

// MARK: - DuplicateResolutionOption

public enum DuplicateResolutionOption {
    case skip
    case replace
    case keepBoth
    case resumeExisting
}

// MARK: - DownloadURLValidationResult

public enum DownloadURLValidationResult {
    case valid(URL)
    case invalid(String)
}

// MARK: - DownloadsViewModel

@MainActor
public final class DownloadsViewModel: ObservableObject {

    // ── Filter / Sort ──────────────────────────────────────────────────────
    @Published public var filterState: DownloadFilterState {
        didSet { filterState.save(); applyFilter() }
    }
    @Published public private(set) var displayedTasks: [DownloadTaskModel] = []

    // Convenience counts for badge display
    @Published public private(set) var countByFilter: [DownloadStatusFilter: Int] = [:]

    // ── Selection (Batch) ─────────────────────────────────────────────────
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedIDs: Set<UUID> = []

    // ── Sheet presentation ────────────────────────────────────────────────
    @Published public var isAddSheetPresented: Bool = false
    @Published public var isQueueSettingsPresented: Bool = false
    @Published public var taskForInfoSheet: DownloadTaskModel?
    @Published public var taskForDiagnosticsSheet: DownloadTaskModel?
    @Published public var taskForUpdateURLSheet: DownloadTaskModel?
    @Published public var taskForMirrorSheet: DownloadTaskModel?

    // ── Duplicate detection ───────────────────────────────────────────────
    @Published public var pendingDuplicateURL: URL?
    @Published public var pendingDuplicateFilename: String?
    @Published public var duplicateExistingTask: DownloadTaskModel?
    @Published public var isDuplicateAlertPresented: Bool = false

    // Legacy single-message compat
    @Published public var duplicateWarningMessage: String?

    // ── Delete confirmation ───────────────────────────────────────────────
    @Published public var pendingDeleteID: UUID?
    @Published public var isDeleteConfirmationPresented: Bool = false
    @Published public var isBatchDeleteConfirmationPresented: Bool = false

    // ── Storage ───────────────────────────────────────────────────────────
    @Published public private(set) var freeDiskSpaceFormatted: String = "0 B"
    @Published public private(set) var appUsageFormatted: String = "0 B"
    @Published public private(set) var storageUsedPercentage: Double = 0.0
    @Published public private(set) var queueModeFormatted: String = "Parallel"
    @Published public private(set) var maxConcurrentDownloads: Int = 3

    // ── Dependencies ──────────────────────────────────────────────────────
    public let downloadEngine: DownloadEngineProtocol
    public let fileManagerService: FileManagementServiceProtocol
    public let storageManager: StorageManagerProtocol
    public let queueManager: QueueManagerProtocol
    private let hapticService: HapticServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    private var _allTasks: [DownloadTaskModel] = []

    // MARK: init

    public init(
        downloadEngine:     DownloadEngineProtocol         = ServiceContainer.shared.downloadEngine,
        fileManagerService: FileManagementServiceProtocol  = ServiceContainer.shared.fileManagementService,
        storageManager:     StorageManagerProtocol         = ServiceContainer.shared.storageManager,
        queueManager:       QueueManagerProtocol           = ServiceContainer.shared.queueManager,
        hapticService:      HapticServiceProtocol          = ServiceContainer.shared.hapticService
    ) {
        self.downloadEngine      = downloadEngine
        self.fileManagerService  = fileManagerService
        self.storageManager      = storageManager
        self.queueManager        = queueManager
        self.hapticService       = hapticService
        self.filterState         = DownloadFilterState.load()

        downloadEngine.tasksPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                self?._allTasks = tasks
                self?.applyFilter()
                self?.computeCounts(tasks)
            }
            .store(in: &cancellables)

        _allTasks = downloadEngine.tasks
        applyFilter()
        computeCounts(_allTasks)
        refreshStorageInfo()
    }

    // MARK: ── Filter helpers ──────────────────────────────────────────────

    private func applyFilter() {
        displayedTasks = applyFilterAndSort(_allTasks, state: filterState)
    }

    private func computeCounts(_ tasks: [DownloadTaskModel]) {
        var counts: [DownloadStatusFilter: Int] = [:]
        for filter in DownloadStatusFilter.allCases {
            counts[filter] = tasks.filter { filter.matches($0.status) }.count
        }
        counts[.all] = tasks.count
        countByFilter = counts
    }

    // MARK: ── Storage ─────────────────────────────────────────────────────

    public func refreshStorageInfo(forceDiskScan: Bool = false) {
        if forceDiskScan { storageManager.invalidateCache() }
        freeDiskSpaceFormatted = storageManager.formattedFreeDiskSpace
        appUsageFormatted      = storageManager.formattedAppDownloadsUsage
        storageUsedPercentage  = storageManager.storageUsedPercentage
        queueModeFormatted     = queueManager.queueMode.rawValue
        maxConcurrentDownloads = queueManager.maxConcurrentDownloads
    }

    // MARK: ── Download actions ────────────────────────────────────────────

    public func startNewDownload(url: URL, filename: String?) {
        guard let engine = downloadEngine as? DownloadEngine else {
            _ = downloadEngine.startDownload(url: url, filename: filename)
            queueManager.scheduleNextTasks(in: downloadEngine)
            refreshStorageInfo()
            return
        }

        // Full duplicate detection
        if queueManager.isDuplicate(url: url, in: downloadEngine) {
            let existing = downloadEngine.tasks.first {
                $0.url.absoluteString.lowercased() == url.absoluteString.lowercased()
                && $0.status != .failed && $0.status != .cancelled
            }
            pendingDuplicateURL      = url
            pendingDuplicateFilename = filename
            duplicateExistingTask    = existing
            isDuplicateAlertPresented = true
            duplicateWarningMessage  = "A download with this URL already exists."
            hapticService.notificationOccurred(.warning)
            return
        }

        _ = downloadEngine.startDownload(url: url, filename: filename)
        queueManager.scheduleNextTasks(in: downloadEngine)
        refreshStorageInfo()
    }

    public func resolveDuplicate(_ option: DuplicateResolutionOption) {
        guard let url = pendingDuplicateURL else { return }
        let filename = pendingDuplicateFilename

        switch option {
        case .skip:
            break

        case .replace:
            if let existing = duplicateExistingTask {
                downloadEngine.deleteDownload(id: existing.id, deleteFile: true)
            }
            _ = downloadEngine.startDownload(url: url, filename: filename)
            queueManager.scheduleNextTasks(in: downloadEngine)

        case .keepBoth:
            _ = downloadEngine.startDownload(url: url, filename: filename)
            queueManager.scheduleNextTasks(in: downloadEngine)

        case .resumeExisting:
            if let existing = duplicateExistingTask,
               existing.status == .paused || existing.status == .failed {
                downloadEngine.resumeDownload(id: existing.id)
                queueManager.scheduleNextTasks(in: downloadEngine)
            }
        }

        pendingDuplicateURL      = nil
        pendingDuplicateFilename = nil
        duplicateExistingTask    = nil
        isDuplicateAlertPresented = false
    }

    public func pauseTask(id: UUID) {
        downloadEngine.pauseDownload(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
    }

    public func resumeTask(id: UUID) {
        downloadEngine.resumeDownload(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
    }

    public func cancelTask(id: UUID) {
        downloadEngine.cancelDownload(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
    }

    public func retryTask(id: UUID) {
        downloadEngine.retryDownload(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
    }

    public func deleteTask(id: UUID, deleteFile: Bool = true) {
        downloadEngine.deleteDownload(id: id, deleteFile: deleteFile)
        queueManager.scheduleNextTasks(in: downloadEngine)
        refreshStorageInfo(forceDiskScan: true)
    }

    public func confirmDeleteTask(id: UUID) {
        pendingDeleteID = id
        isDeleteConfirmationPresented = true
    }

    public func shareTask(task: DownloadTaskModel) {
        guard let path = task.destinationPath else { return }
        fileManagerService.shareFile(url: URL(fileURLWithPath: path), from: nil)
        hapticService.impactOccurred(.light)
    }

    public func changeTaskPriority(id: UUID, newPriority: DownloadPriority) {
        queueManager.changePriority(for: id, to: newPriority, in: downloadEngine)
        hapticService.selectionChanged()
    }

    public func moveTask(from sourceIndex: Int, to destinationIndex: Int) {
        queueManager.moveTask(from: sourceIndex, to: destinationIndex, in: downloadEngine)
        hapticService.selectionChanged()
    }

    // MARK: ── URL Update ─────────────────────────────────────────────────

    public func validateURL(_ string: String) -> DownloadURLValidationResult {
        var clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.lowercased().hasPrefix("http://") && !clean.lowercased().hasPrefix("https://") {
            clean = "https://" + clean
        }
        guard let url = URL(string: clean), UIApplication.shared.canOpenURL(url) else {
            return .invalid("Please enter a valid HTTP or HTTPS URL.")
        }
        return .valid(url)
    }

    public func updateDownloadURL(_ newURL: URL, for id: UUID) {
        guard let engine = downloadEngine as? DownloadEngine else { return }
        engine.updateURL(newURL, for: id)
        taskForUpdateURLSheet = nil
        hapticService.notificationOccurred(.success)
    }

    // MARK: ── Batch Operations ────────────────────────────────────────────

    public func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode { selectedIDs.removeAll() }
        hapticService.impactOccurred(.light)
    }

    public func toggleSelection(id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    public func selectAll() {
        selectedIDs = Set(displayedTasks.map { $0.id })
        hapticService.selectionChanged()
    }

    public func deselectAll() {
        selectedIDs.removeAll()
        hapticService.selectionChanged()
    }

    public func batchPause() {
        guard let engine = downloadEngine as? DownloadEngine else { return }
        DownloadBatchManager.shared.pauseAll(ids: selectedIDs, engine: engine)
        hapticService.impactOccurred(.medium)
    }

    public func batchResume() {
        guard let engine = downloadEngine as? DownloadEngine else { return }
        DownloadBatchManager.shared.resumeAll(ids: selectedIDs, engine: engine)
        hapticService.impactOccurred(.medium)
    }

    public func batchRetry() {
        guard let engine = downloadEngine as? DownloadEngine else { return }
        DownloadBatchManager.shared.retryAll(ids: selectedIDs, engine: engine)
        hapticService.impactOccurred(.medium)
    }

    public func batchDelete(deleteFiles: Bool) {
        guard let engine = downloadEngine as? DownloadEngine else { return }
        DownloadBatchManager.shared.deleteAll(ids: selectedIDs, engine: engine, deleteFiles: deleteFiles)
        selectedIDs.removeAll()
        isSelectionMode = false
        refreshStorageInfo(forceDiskScan: true)
        hapticService.notificationOccurred(.error)
    }

    // MARK: ── Computed helpers ────────────────────────────────────────────

    public var selectedCount: Int { selectedIDs.count }

    public var canBatchPause: Bool {
        selectedIDs.contains { id in
            displayedTasks.first { $0.id == id }?.status == .downloading ||
            displayedTasks.first { $0.id == id }?.status == .pending
        }
    }

    public var canBatchResume: Bool {
        selectedIDs.contains { id in
            let s = displayedTasks.first { $0.id == id }?.status
            return s == .paused || s == .failed
        }
    }

    public var canBatchRetry: Bool {
        selectedIDs.contains { id in
            let s = displayedTasks.first { $0.id == id }?.status
            return s == .failed || s == .cancelled
        }
    }

    // Legacy compat
    public var activeTasks: [DownloadTaskModel] {
        _allTasks.filter { $0.status != .completed }
    }
    public var completedTasks: [DownloadTaskModel] {
        _allTasks.filter { $0.status == .completed }
    }
}
