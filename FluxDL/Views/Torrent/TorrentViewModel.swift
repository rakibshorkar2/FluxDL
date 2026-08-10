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
    case finished = "Finished"

    public var id: String { rawValue }

    public func matches(_ torrent: TorrentTaskModel) -> Bool {
        switch self {
        case .all: return true
        case .downloading:
            switch torrent.state {
            case .downloading, .downloadingMetadata, .checkingFiles, .checkingResumeData: return true
            default: return false
            }
        case .seeding: return torrent.state == .seeding
        case .paused: return torrent.state == .paused
        case .finished: return torrent.state == .finished
        }
    }
}

public enum TorrentSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case progress = "Progress"
    case downloadRate = "Download Speed"
    case uploadRate = "Upload Speed"
    case eta = "Time Left"

    public var id: String { rawValue }

    fileprivate func compare(_ lhs: TorrentTaskModel, _ rhs: TorrentTaskModel) -> Bool {
        switch self {
        case .name: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .size: return lhs.total > rhs.total
        case .progress: return lhs.progress < rhs.progress
        case .downloadRate: return lhs.downloadRate > rhs.downloadRate
        case .uploadRate: return lhs.uploadRate > rhs.uploadRate
        case .eta: return (lhs.eta ?? .infinity) < (rhs.eta ?? .infinity)
        }
    }
}

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
    @Published public var sortOrder: TorrentSortOrder = .name

    /// Torrents filtered by search text and state, sorted per `sortOrder`.
    public var visibleTorrents: [TorrentTaskModel] {
        var result = torrents
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        result = result.filter { filter.matches($0) }
        result.sort(by: sortOrder.compare)
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

    // ── Undo removal ──────────────────────────────────────────────────────
    @Published public var undoToast: TorrentUndoToast?

    private var undoToastTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(service: TorrentService = TorrentService()) {
        self.service = service

        service.$torrents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] torrents in
                guard let self = self else { return }
                self.torrents = torrents
                self.totalDownloadRate = torrents.reduce(0) { $0 + $1.downloadRate }
                self.totalUploadRate = torrents.reduce(0) { $0 + $1.uploadRate }
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

    // MARK: ── Session ────────────────────────────────────────────────────

    public func startSessionIfNeeded() {
        service.startSession()
    }

    // MARK: ── Add actions ─────────────────────────────────────────────────

    public func addMagnet(_ string: String, options: AddTorrentOptions = AddTorrentOptions()) -> Bool {
        switch service.addMagnet(string, options: options) {
        case .success: return true
        case .failure(let error): presentError(error.localizedDescription); return false
        }
    }

    public func addTorrentFile(at url: URL, options: AddTorrentOptions = AddTorrentOptions()) -> Bool {
        switch service.addTorrentFile(at: url, options: options) {
        case .success: return true
        case .failure(let error): presentError(error.localizedDescription); return false
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
        if taskForDetail?.id == id { taskForDetail = nil }

        // Removal that keeps files is reversible: offer a short undo window.
        // Deleting files is not undoable, so it only shows the deleting state.
        guard !deleteFiles, let model = removedModel else { return }
        presentUndoToast(for: model)
    }

    /// Re-adds the last keep-files removal from its saved magnet link.
    public func undoRemoval() {
        guard let toast = undoToast else { return }
        undoToast = nil
        undoToastTask?.cancel()
        guard let magnet = toast.magnetLink else {
            presentError("This torrent could not be restored automatically.")
            return
        }
        _ = addMagnet(magnet)
    }

    public func dismissUndoToast() {
        undoToast = nil
        undoToastTask?.cancel()
    }

    private func presentUndoToast(for model: TorrentTaskModel) {
        undoToastTask?.cancel()
        undoToast = TorrentUndoToast(id: model.id, name: model.name, magnetLink: model.magnetLink)
        undoToastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.undoToast = nil
        }
    }

    public func pauseAll() { service.pauseAll() }

    public func resumeAll() { service.resumeAll() }

    public func copyMagnetLink(_ id: String) {
        guard let torrent = torrents.first(where: { $0.id == id }),
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

    public func setNotificationsEnabled(_ enabled: Bool) {
        service.setNotificationsEnabled(enabled)
    }

    public func forceReannounce(_ id: String) {
        service.forceReannounce(id)
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

public struct TorrentUndoToast: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let magnetLink: String?
}
