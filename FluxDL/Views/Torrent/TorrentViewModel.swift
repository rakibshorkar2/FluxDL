import Foundation
import Combine
import UIKit
import LibTorrent

// MARK: - Filtering / Sorting

public enum TorrentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloading = "Downloading"
    case seeding = "Seeding"
    case paused = "Paused"
    case completed = "Completed"
    case stalled = "Stalled"
    case error = "Error"

    public var id: String { rawValue }

    public func matches(_ torrent: TorrentTaskModel) -> Bool {
        switch self {
        case .all:
            return true
        case .downloading:
            if torrent.isStalled { return false }
            switch torrent.state {
            case .downloading, .downloadingMetadata, .checkingFiles, .checkingResumeData: return true
            default: return false
            }
        case .seeding:
            return torrent.state == .seeding
        case .paused:
            return torrent.state == .paused
        case .completed:
            return torrent.state == .finished
        case .stalled:
            return torrent.isStalled
        case .error:
            return torrent.state == .storageError
        }
    }
}

public enum TorrentSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case dateAdded = "Date Added"
    case creationDate = "Created Date"
    case size = "Size"
    case progress = "Progress"
    case downloadRate = "Download Speed"
    case uploadRate = "Upload Speed"
    case eta = "Time Left"
    case status = "Status"
    case ratio = "Ratio"

    public var id: String { rawValue }

    /// Raw comparison value for `order`; used by both directions.
    fileprivate func compareValue(_ torrent: TorrentTaskModel) -> Double {
        switch self {
        case .name: return 0
        case .dateAdded: return torrent.createdAt.timeIntervalSince1970
        case .creationDate: return torrent.creationDate?.timeIntervalSince1970 ?? 0
        case .size: return Double(torrent.total)
        case .progress: return torrent.clampedProgress
        case .downloadRate: return Double(torrent.downloadRate)
        case .uploadRate: return Double(torrent.uploadRate)
        case .eta: return torrent.eta ?? .infinity
        case .status: return Double(torrent.state.sortRank)
        case .ratio: return torrent.ratio ?? -1
        }
    }
}

public enum TorrentSortDirection: String, CaseIterable, Identifiable {
    case ascending = "Ascending"
    case descending = "Descending"

    public var id: String { rawValue }
}

// MARK: - View Model

@MainActor
public final class TorrentViewModel: ObservableObject {

    // ── Dependencies ──────────────────────────────────────────────────────
    public let service: TorrentService

    // ── Published state ───────────────────────────────────────────────────
    @Published public private(set) var torrents: [TorrentTaskModel] = []
    @Published public private(set) var deletingTorrents: [TorrentTaskModel] = []
    @Published public private(set) var isSessionActive = false
    @Published public private(set) var totalDownloadRate: Int64 = 0
    @Published public private(set) var totalUploadRate: Int64 = 0

    // ── Search / filter / sort ────────────────────────────────────────────
    @Published public var searchText = ""
    @Published public var filter: TorrentFilter = .all
    @Published public var sortOrder: TorrentSortOrder {
        didSet { persistSort() }
    }
    @Published public var sortDirection: TorrentSortDirection {
        didSet { persistSort() }
    }

    /// Torrents filtered by search text and state, sorted per `sortOrder`.
    public var visibleTorrents: [TorrentTaskModel] {
        var result = torrents
        if !searchText.isEmpty {
            let needle = searchText
            result = result.filter { torrent in
                if torrent.name.localizedCaseInsensitiveContains(needle) { return true }
                return torrent.files.contains { $0.name.localizedCaseInsensitiveContains(needle) }
            }
        }
        result = result.filter { filter.matches($0) }
        result.sort { lhs, rhs in
            let ascending: Bool
            if sortOrder == .name {
                ascending = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            } else {
                ascending = sortOrder.compareValue(lhs) < sortOrder.compareValue(rhs)
            }
            return sortDirection == .ascending ? ascending : !ascending
        }
        return result
    }

    /// Everything shown in the list: live torrents first, then the ones whose
    /// files are still being deleted from disk.
    public var displayedTorrents: [TorrentTaskModel] {
        visibleTorrents + deletingTorrents
    }

    public func isDeleting(_ id: String) -> Bool {
        deletingTorrents.contains { $0.id == id }
    }

    // ── Sheet presentation ────────────────────────────────────────────────
    @Published public var isAddSheetPresented = false
    @Published public var taskForDetail: TorrentTaskModel?

    // ── Alerts ────────────────────────────────────────────────────────────
    @Published public var alertMessage: String?
    @Published public var isAlertPresented = false

    // ── Multi-selection edit mode ─────────────────────────────────────────
    @Published public var isEditing = false
    /// Stable torrent ids (info-hash hex) selected in edit mode.
    /// Never array indexes: sorting/filtering may reorder the list at any time.
    @Published public private(set) var selectedIDs: Set<String> = []

    // ── Undo removal ──────────────────────────────────────────────────────
    @Published public var undoToast: TorrentUndoToast?

    private var undoToastTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private enum PreferencesKey {
        static let sortOrder = "Torrent.SortOrder"
        static let sortDirection = "Torrent.SortDirection"
    }

    public init(service: TorrentService = TorrentService()) {
        self.service = service
        let defaults = UserDefaults.standard
        self.sortOrder = TorrentSortOrder(rawValue: defaults.string(forKey: PreferencesKey.sortOrder) ?? "") ?? .name
        self.sortDirection = TorrentSortDirection(rawValue: defaults.string(forKey: PreferencesKey.sortDirection) ?? "") ?? .ascending

        service.$torrents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] torrents in
                guard let self = self else { return }
                self.torrents = torrents
                self.totalDownloadRate = torrents.reduce(0) { $0 + $1.downloadRate }
                self.totalUploadRate = torrents.reduce(0) { $0 + $1.uploadRate }
                self.pruneSelection(to: torrents)
            }
            .store(in: &cancellables)

        service.$deletingTorrents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deleting in
                self?.deletingTorrents = deleting
            }
            .store(in: &cancellables)

        service.$isSessionActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.isSessionActive = active }
            .store(in: &cancellables)

        service.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] message in self?.presentError(message) }
            .store(in: &cancellables)
    }

    private func persistSort() {
        UserDefaults.standard.set(sortOrder.rawValue, forKey: PreferencesKey.sortOrder)
        UserDefaults.standard.set(sortDirection.rawValue, forKey: PreferencesKey.sortDirection)
    }

    // MARK: ── Session ────────────────────────────────────────────────────

    public func startSessionIfNeeded() {
        service.startSession()
    }

    // MARK: ── Add actions ─────────────────────────────────────────────────

    /// Adds a magnet link. Returns an error message on failure, nil on success.
    public func addMagnet(_ string: String, options: AddTorrentOptions = AddTorrentOptions()) -> String? {
        switch service.addMagnet(string, options: options) {
        case .success: return nil
        case .failure(let error): return error.localizedDescription
        }
    }

    /// Adds a `.torrent` file picked from the document picker. Returns an
    /// error message on failure, nil on success.
    public func addTorrentFile(at url: URL, options: AddTorrentOptions = AddTorrentOptions()) -> String? {
        switch service.addTorrentFile(at: url, options: options) {
        case .success: return nil
        case .failure(let error): return error.localizedDescription
        }
    }

    public func addRemoteTorrent(_ url: URL, options: AddTorrentOptions = AddTorrentOptions()) {
        Task {
            do {
                let torrentFile = try await TorrentFile.download(from: url)
                switch service.addTorrent(torrentFile, options: options) {
                case .success: break
                case .failure(let error): presentError(error.localizedDescription)
                }
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    // MARK: ── Torrent actions ─────────────────────────────────────────────

    public func pause(_ id: String) { service.pauseTorrent(id) }

    public func resume(_ id: String) { service.resumeTorrent(id) }

    public func rehash(_ id: String) { service.rehashTorrent(id) }

    public func remove(_ id: String, deleteFiles: Bool) {
        let removedModel = liveModel(for: id)
        service.removeTorrent(id, deleteFiles: deleteFiles)
        selectedIDs.remove(id)
        if taskForDetail?.id == id { taskForDetail = nil }

        // Removal that keeps files is reversible: offer a short undo window.
        // Deleting files is not undoable, so it only shows the deleting state.
        guard !deleteFiles, let model = removedModel else { return }
        presentUndoToast(for: [model])
    }

    /// Re-adds the last keep-files removals from their saved magnet links.
    public func undoRemoval() {
        guard let toast = undoToast else { return }
        undoToast = nil
        undoToastTask?.cancel()
        let records = toast.records
        guard !records.isEmpty else { return }

        var failedCount = 0
        for record in records {
            guard let magnet = record.magnetLink else {
                failedCount += 1
                continue
            }
            if addMagnet(magnet) != nil { failedCount += 1 }
        }
        if failedCount > 0 {
            presentError(failedCount == records.count
                ? "These torrents could not be restored automatically."
                : "Some torrents could not be restored automatically.")
        }
    }

    public func dismissUndoToast() {
        undoToast = nil
        undoToastTask?.cancel()
    }

    private func presentUndoToast(for models: [TorrentTaskModel]) {
        guard !models.isEmpty else { return }
        undoToastTask?.cancel()
        undoToast = TorrentUndoToast(records: models.map {
            TorrentRemovalRecord(id: $0.id, name: $0.name, magnetLink: $0.magnetLink)
        })
        undoToastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.undoToast = nil
        }
    }

    public func pauseAll() { service.pauseAll() }

    public func resumeAll() { service.resumeAll() }

    public func copyMagnetLink(_ id: String) {
        guard let torrent = liveModel(for: id),
              let magnet = torrent.magnetLink else { return }
        UIPasteboard.general.string = magnet
    }

    public func setFilePriority(_ id: String, index: Int, priority: FileEntry.Priority) {
        service.setFilePriority(id, index: index, priority: priority)
    }

    public func setAllFilesPriority(_ id: String, priority: FileEntry.Priority) {
        service.setAllFilesPriority(id, priority: priority)
    }

    public func addTracker(_ id: String, url: String) {
        let cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        service.addTracker(id, url: cleaned)
    }

    public func setStopSeeding(_ id: String, enabled: Bool) {
        service.setStopSeeding(id, enabled: enabled)
    }

    public func setDownloadLimit(_ id: String, bytesPerSecond: Int64) {
        service.setDownloadLimit(id, bytesPerSecond: bytesPerSecond)
    }

    public func setUploadLimit(_ id: String, bytesPerSecond: Int64) {
        service.setUploadLimit(id, bytesPerSecond: bytesPerSecond)
    }

    public func setSequentialDownload(_ id: String, enabled: Bool) {
        service.setSequentialDownload(id, enabled: enabled)
    }

    public func setFirstLastPriorityDownload(_ id: String, enabled: Bool) {
        service.setFirstLastPriorityDownload(id, enabled: enabled)
    }

    public func removeTracker(_ id: String, url: String) {
        service.removeTracker(id, url: url)
    }

    public func setGlobalDownloadSpeed(_ bytesPerSecond: Int64) {
        service.setGlobalDownloadSpeed(bytesPerSecond)
    }

    public func setGlobalUploadSpeed(_ bytesPerSecond: Int64) {
        service.setGlobalUploadSpeed(bytesPerSecond)
    }

    public func setQueueLimits(maxActive: Int, maxDownloading: Int, maxUploading: Int) {
        service.setQueueLimits(maxActive: maxActive, maxDownloading: maxDownloading, maxUploading: maxUploading)
    }

    public func updateConnectionSettings(_ settings: TorrentConnectionSettings) {
        service.updateConnectionSettings(settings)
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        service.setNotificationsEnabled(enabled)
    }

    public func forceReannounce(_ id: String) {
        service.forceReannounce(id)
    }

    // MARK: ── Multi-selection edit mode ───────────────────────────────────

    public func enterEditMode() {
        isEditing = true
    }

    public func exitEditMode() {
        isEditing = false
        selectedIDs.removeAll()
    }

    public func toggleEditMode() {
        isEditing ? exitEditMode() : enterEditMode()
    }

    public func isSelected(_ id: String) -> Bool {
        selectedIDs.contains(id)
    }

    public func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// Selects every torrent currently matching search + filter.
    public func selectAllVisible() {
        selectedIDs = Set(visibleTorrents.map(\.id))
    }

    public func deselectAll() {
        selectedIDs.removeAll()
    }

    /// Whether the selection contains at least one torrent that can be paused.
    public var canPauseSelection: Bool {
        selectedTorrents.contains { !$0.isPaused && $0.state != .storageError }
    }

    /// Whether the selection contains at least one torrent that can be resumed.
    public var canResumeSelection: Bool {
        selectedTorrents.contains { $0.isPaused || $0.state == .storageError }
    }

    public var selectedTorrents: [TorrentTaskModel] {
        torrents.filter { selectedIDs.contains($0.id) }
    }

    public func pauseSelected() {
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else { return }
        service.pauseTorrents(ids)
    }

    public func resumeSelected() {
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else { return }
        service.resumeTorrents(ids)
    }

    public func removeSelected(deleteFiles: Bool) {
        let models = selectedTorrents
        guard !models.isEmpty else { return }
        service.removeTorrents(models.map(\.id), deleteFiles: deleteFiles)

        if !deleteFiles {
            presentUndoToast(for: models)
        }

        if let detail = taskForDetail, models.contains(where: { $0.id == detail.id }) {
            taskForDetail = nil
        }
        selectedIDs.removeAll()
        if isEditing && torrents.isEmpty {
            exitEditMode()
        }
    }

    /// Prunes selection after the underlying torrents change so it never
    /// references torrents that no longer exist.
    private func pruneSelection(to models: [TorrentTaskModel]) {
        guard !selectedIDs.isEmpty else { return }
        let existing = Set(models.map(\.id))
        let pruned = selectedIDs.intersection(existing)
        if pruned != selectedIDs {
            selectedIDs = pruned
        }
        if pruned.isEmpty && isEditing {
            exitEditMode()
        }
    }

    // MARK: ── Helpers ─────────────────────────────────────────────────────

    public func liveModel(for id: String) -> TorrentTaskModel? {
        torrents.first { $0.id == id }
    }

    private func presentError(_ message: String) {
        alertMessage = message
        isAlertPresented = true
    }
}

// MARK: - Undo Removal Toast

public struct TorrentRemovalRecord: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let magnetLink: String?
}

public struct TorrentUndoToast: Equatable, Identifiable {
    public var id: String { records.map(\.id).joined(separator: ",") }
    public let records: [TorrentRemovalRecord]

    public var title: String {
        switch records.count {
        case 0: return "Torrent Removed"
        case 1: return "Torrent Removed"
        default: return "\(records.count) Torrents Removed"
        }
    }

    public var subtitle: String {
        guard let first = records.first else { return "" }
        return records.count == 1 ? first.name : "\(first.name) and \(records.count - 1) more"
    }
}