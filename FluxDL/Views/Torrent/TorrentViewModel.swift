import Foundation
import Combine
import UIKit
import LibTorrent

@MainActor
public final class TorrentViewModel: ObservableObject {

    // ── Dependencies ──────────────────────────────────────────────────────
    public let service: TorrentService

    // ── Published state ───────────────────────────────────────────────────
    @Published public private(set) var torrents: [TorrentTaskModel] = []
    @Published public private(set) var isSessionActive = false
    @Published public private(set) var totalDownloadRate: Int64 = 0
    @Published public private(set) var totalUploadRate: Int64 = 0

    // ── Sheet presentation ────────────────────────────────────────────────
    @Published public var isAddSheetPresented = false
    @Published public var taskForDetail: TorrentTaskModel?

    // ── Alerts ────────────────────────────────────────────────────────────
    @Published public var alertMessage: String?
    @Published public var isAlertPresented = false

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

    public func addMagnet(_ string: String) -> Bool {
        switch service.addMagnet(string) {
        case .success: return true
        case .failure(let error): presentError(error.localizedDescription); return false
        }
    }

    public func addTorrentFile(at url: URL) -> Bool {
        switch service.addTorrentFile(at: url) {
        case .success: return true
        case .failure(let error): presentError(error.localizedDescription); return false
        }
    }

    public func addRemoteTorrent(_ url: URL) {
        Task {
            do {
                let torrentFile = try await TorrentFile.download(from: url)
                switch service.addTorrent(torrentFile) {
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
        service.removeTorrent(id, deleteFiles: deleteFiles)
        if taskForDetail?.id == id { taskForDetail = nil }
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
