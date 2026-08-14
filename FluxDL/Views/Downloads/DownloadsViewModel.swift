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
    /// Unified list: standalone tasks + folder download groups.
    @Published public private(set) var displayedItems: [DownloadDisplayItem] = []
    /// Folder groups the user expanded (children visible).
    @Published public private(set) var expandedGroupIDs: Set<UUID> = []

    /// Standalone tasks currently displayed (folder children are hidden and
    /// rendered inside their group card). Kept for batch/legacy use.
    public var displayedTasks: [DownloadTaskModel] {
        displayedItems.compactMap {
            if case .task(let task) = $0 { return task } else { return nil }
        }
    }

    // Convenience counts for badge display
    @Published public private(set) var countByFilter: [DownloadStatusFilter: Int] = [:]

    // ── Selection (Batch) ─────────────────────────────────────────────────
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedIDs: Set<UUID> = []

    // ── Sheet presentation ────────────────────────────────────────────────
    @Published public var isAddSheetPresented: Bool = false
    @Published public var isQueueSettingsPresented: Bool = false
    @Published public var isHistoryPresented: Bool = false
    @Published public var taskForInfoSheet: DownloadTaskModel?
    @Published public var taskForDiagnosticsSheet: DownloadTaskModel?
    @Published public var taskForUpdateURLSheet: DownloadTaskModel?
    @Published public var taskForMirrorSheet: DownloadTaskModel?

    // ── Clipboard detection (owned by the Downloads tab) ──────────────────
    /// Mirror of `ClipboardService.detectedURL`, rendered by DownloadsView's
    /// banner. Cleared when the download starts or the banner is dismissed.
    @Published public private(set) var clipboardDetectedURL: URL?

    // ── Duplicate detection ───────────────────────────────────────────────
    @Published public var pendingDuplicateURL: URL?
    @Published public var pendingDuplicateFilename: String?
    @Published public var duplicateExistingTask: DownloadTaskModel?
    @Published public var isDuplicateAlertPresented: Bool = false

    // Legacy single-message compat
    @Published public var duplicateWarningMessage: String?

    // ── Delete confirmation ───────────────────────────────────────────────
    // Single-item delete confirmation is row-local (see DownloadItemCard) and
    // resolves its target by the row's stable `DownloadTaskModel.id`.
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
    public let historyManager: DownloadHistoryManager
    public let folderCoordinator: FolderDownloadCoordinator
    private let clipboardService: ClipboardServiceProtocol
    private let hapticService: HapticServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    private var _allTasks: [DownloadTaskModel] = []
    /// Group IDs already seen, so newly created groups auto-expand exactly
    /// once instead of on every filter/sort change.
    private var seenGroupIDs: Set<UUID> = []

    /// Guards against double-starts from rapid repeated taps on the
    /// clipboard banner Download button.
    private var isClipboardDownloadInFlight = false

    // MARK: init

    public init(
        downloadEngine:     DownloadEngineProtocol         = ServiceContainer.shared.downloadEngine,
        fileManagerService: FileManagementServiceProtocol  = ServiceContainer.shared.fileManagementService,
        storageManager:     StorageManagerProtocol         = ServiceContainer.shared.storageManager,
        queueManager:       QueueManagerProtocol           = ServiceContainer.shared.queueManager,
        historyManager:     DownloadHistoryManager         = ServiceContainer.shared.downloadHistoryManager,
        folderCoordinator:  FolderDownloadCoordinator      = ServiceContainer.shared.folderDownloadCoordinator,
        clipboardService:   ClipboardServiceProtocol       = ServiceContainer.shared.clipboardService,
        hapticService:      HapticServiceProtocol          = ServiceContainer.shared.hapticService
    ) {
        self.downloadEngine      = downloadEngine
        self.fileManagerService  = fileManagerService
        self.storageManager      = storageManager
        self.queueManager        = queueManager
        self.historyManager      = historyManager
        self.folderCoordinator   = folderCoordinator
        self.clipboardService    = clipboardService
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

        // Folder group metadata changes (create/remove) re-run the list.
        folderCoordinator.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFilter()
            }
            .store(in: &cancellables)

        // The Downloads tab owns the clipboard prompt. When the banner is
        // acted on (or the tab is left), the detection state is cleared here.
        clipboardService.detectedURLPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.clipboardDetectedURL = url
            }
            .store(in: &cancellables)

        _allTasks = downloadEngine.tasks
        applyFilter()
        computeCounts(_allTasks)
        refreshStorageInfo()
    }

    // MARK: ── Filter helpers ──────────────────────────────────────────────

    private func applyFilter() {
        // Children of folder groups are hidden from the flat list; the group
        // itself appears as one expandable row.
        let standalone = _allTasks.filter { $0.folderGroupID == nil }
        var items: [DownloadDisplayItem] = standalone.map { .task($0) }
        for group in folderCoordinator.groups {
            items.append(.folder(folderCoordinator.snapshot(for: group)))
            if !seenGroupIDs.contains(group.id) {
                seenGroupIDs.insert(group.id)
                expandedGroupIDs.insert(group.id)
            }
        }
        displayedItems = applyFilterAndSortItems(items, state: filterState)
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

    // MARK: ── Clipboard banner ────────────────────────────────────────────

    /// Starts the download for a URL detected on the clipboard.
    ///
    /// The banner is dismissed first (so a repeated tap can never start a
    /// second download), and the `isClipboardDownloadInFlight` guard covers
    /// double-taps within the same frame before the view re-renders.
    public func startDownloadFromClipboard() {
        guard let url = clipboardDetectedURL else { return }
        guard !isClipboardDownloadInFlight else { return }
        isClipboardDownloadInFlight = true
        defer { isClipboardDownloadInFlight = false }

        dismissClipboardDetection()
        startNewDownload(url: url, filename: nil)
        hapticService.impactOccurred(.light)
    }

    /// Clears both the view-level banner state and the underlying clipboard
    /// detection state — never just hides the banner visually.
    public func dismissClipboardDetection() {
        clipboardDetectedURL = nil
        clipboardService.dismissDetectedURL()
    }

    // MARK: ── History ─────────────────────────────────────────────────────

    /// Restarts a download from a history record's saved original URL.
    /// The history sheet is dismissed first so the duplicate-resolution sheet
    /// (if the URL already exists) can present cleanly afterwards.
    public func retryFromHistory(entry: DownloadHistoryEntry) {
        isHistoryPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startNewDownload(url: entry.originalURL, filename: entry.filename)
            }
        }
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

    // MARK: ── Folder download groups ──────────────────────────────────────

    public func toggleGroupExpanded(id: UUID) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
        hapticService.selectionChanged()
    }

    public func pauseFolder(id: UUID) {
        folderCoordinator.pauseFolder(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
        hapticService.impactOccurred(.light)
    }

    public func resumeFolder(id: UUID) {
        folderCoordinator.resumeFolder(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
        hapticService.impactOccurred(.light)
    }

    public func retryFailedFolder(id: UUID) {
        folderCoordinator.retryFailedFolder(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
        hapticService.impactOccurred(.light)
    }

    public func cancelFolder(id: UUID) {
        folderCoordinator.cancelFolder(id: id)
        queueManager.scheduleNextTasks(in: downloadEngine)
        hapticService.impactOccurred(.light)
    }

    /// Removes a folder group. `deleteFiles` also wipes the folder's
    /// directory tree from disk.
    public func removeFolder(id: UUID, deleteFiles: Bool) {
        folderCoordinator.removeFolder(id: id, deleteFiles: deleteFiles)
        expandedGroupIDs.remove(id)
        queueManager.scheduleNextTasks(in: downloadEngine)
        refreshStorageInfo(forceDiskScan: true)
        hapticService.notificationOccurred(.error)
    }

    /// Detaches one child download from its folder group; the task stays in
    /// Downloads as a normal standalone download.
    public func removeChildFromFolder(taskID: UUID, groupID: UUID) {
        folderCoordinator.removeChild(taskID: taskID, from: groupID)
        queueManager.scheduleNextTasks(in: downloadEngine)
        hapticService.selectionChanged()
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
