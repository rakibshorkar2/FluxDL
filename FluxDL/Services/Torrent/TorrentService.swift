import Foundation
import Combine
import LibTorrent

/// Torrent engine wrapper around the LibTorrent framework.
/// Self-contained: it is created and owned exclusively by the Torrent tab.
public final class TorrentService: NSObject, ObservableObject, SessionDelegate {

    // MARK: - Published State

    @Published public private(set) var torrents: [TorrentTaskModel] = []
    @Published public private(set) var isSessionActive = false
    @Published public private(set) var lastErrorMessage: String?

    // MARK: - Session

    public private(set) var session: Session?

    private var handlesByHash: [String: TorrentHandle] = [:]
    private var updateTimer: Timer?

    // MARK: - Session Lifecycle

    public func startSession() {
        guard session == nil else { return }

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloads = documents.appendingPathComponent("Torrents", isDirectory: true)
        let torrentsDir = downloads.appendingPathComponent(".torrents", isDirectory: true)
        let fastResumeDir = downloads.appendingPathComponent(".fastresume", isDirectory: true)

        let settings = Session.Settings()
        settings.agentName = "FluxDL/1.0"
        settings.peerFingerprint = "-FD1000-"
        settings.maxDownloadSpeed = 0
        settings.maxUploadSpeed = 0
        settings.maxActiveTorrents = 6
        settings.maxDownloadingTorrents = 4
        settings.maxUploadingTorrents = 2
        settings.isDhtEnabled = true
        settings.isLsdEnabled = true
        settings.isUtpEnabled = true
        settings.isUpnpEnabled = true
        settings.isNatEnabled = true
        settings.encryptionPolicy = .enabled
        settings.port = 6881
        settings.portBindRetries = 5

        let session = Session(
            downloadPath: downloads,
            torrentsPath: torrentsDir,
            fastResumePath: fastResumeDir,
            settings: settings,
            storages: [:]
        )
        session.addDelegate(self)
        self.session = session
        isSessionActive = true
        publishCurrentTorrents()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.publishCurrentTorrents()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    // MARK: - Adding Torrents

    public func addMagnet(_ string: String) -> Result<Void, String> {
        guard let session = session else { return .failure("Torrent session is not ready.") }

        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned), url.scheme?.lowercased() == "magnet" else {
            return .failure("Please enter a valid magnet link.")
        }
        guard let magnet = MagnetURI(with: url) else {
            return .failure("Could not parse the magnet link.")
        }
        guard session.addTorrent(magnet) != nil else {
            return .failure("Failed to add the magnet link to the session.")
        }
        return .success(())
    }

    public func addTorrentFile(at url: URL) -> Result<Void, String> {
        guard let session = session else { return .failure("Torrent session is not ready.") }

        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }

        guard let torrentFile = TorrentFile(with: url) else {
            return .failure("Invalid or unsupported .torrent file.")
        }
        return addTorrent(torrentFile)
    }

    public func addTorrentFile(data: Data) -> Result<Void, String> {
        guard let torrentFile = TorrentFile(with: data) else {
            return .failure("Invalid or unsupported .torrent file.")
        }
        return addTorrent(torrentFile)
    }

    public func addTorrent(_ torrentFile: TorrentFile) -> Result<Void, String> {
        guard let session = session else { return .failure("Torrent session is not ready.") }
        guard session.addTorrent(torrentFile) != nil else {
            return .failure("Failed to add the torrent file to the session.")
        }
        return .success(())
    }

    // MARK: - Torrent Actions

    public func pauseTorrent(_ id: String) { handle(id)?.pause() }

    public func resumeTorrent(_ id: String) { handle(id)?.resume() }

    public func rehashTorrent(_ id: String) { handle(id)?.rehash() }

    public func clearTorrentError(_ id: String) { handle(id)?.clearError() }

    public func removeTorrent(_ id: String, deleteFiles: Bool) {
        guard let session = session, let torrent = handle(id) else { return }
        session.removeTorrent(torrent, deleteFiles: deleteFiles)
        handlesByHash.removeValue(forKey: id)
        publishCurrentTorrents()
    }

    public func setFilePriority(_ id: String, index: Int, priority: FileEntry.Priority) {
        handle(id)?.setFilePriority(priority, at: index)
    }

    public func setAllFilesPriority(_ id: String, priority: FileEntry.Priority) {
        handle(id)?.setAllFilesPriority(priority)
    }

    public func addTracker(_ id: String, url: String) {
        handle(id)?.addTracker(url)
    }

    public func forceReannounce(_ id: String) {
        handle(id)?.forceReannounce()
    }

    public func pauseAll() {
        handlesByHash.values.forEach { $0.pause() }
    }

    public func resumeAll() {
        handlesByHash.values.forEach { $0.resume() }
    }

    // MARK: - SessionDelegate

    public func torrentManager(_ manager: Session, didAddTorrent torrent: TorrentHandle) {
        DispatchQueue.main.async { [weak self] in
            self?.handlesByHash[torrent.infoHashes.best.hex] = torrent
            self?.publishCurrentTorrents()
        }
    }

    public func torrentManager(_ manager: Session, didRemoveTorrentWithHash hashesData: TorrentHashes) {
        DispatchQueue.main.async { [weak self] in
            self?.handlesByHash.removeValue(forKey: hashesData.best.hex)
            self?.publishCurrentTorrents()
        }
    }

    public func torrentManager(_ manager: Session, didReceiveUpdateForTorrent torrent: TorrentHandle) {
        DispatchQueue.main.async { [weak self] in
            self?.handlesByHash[torrent.infoHashes.best.hex] = torrent
            self?.publishCurrentTorrents()
        }
    }

    public func torrentManager(_ manager: Session, didErrorOccur error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Snapshot Publishing

    private func publishCurrentTorrents() {
        guard let session = session else { return }

        var currentHashes: Set<String> = []
        var models: [TorrentTaskModel] = []

        for handle in session.torrents {
            let hash = handle.infoHashes.best.hex
            currentHashes.insert(hash)
            if handlesByHash[hash] == nil {
                handlesByHash[hash] = handle
            }
        }

        if handlesByHash.keys.count != currentHashes.count {
            handlesByHash = handlesByHash.filter { currentHashes.contains($0.key) }
        }

        for handle in handlesByHash.values {
            handle.updateSnapshot()
            let snapshot = handle.snapshot
            guard snapshot.isValid else { continue }
            models.append(makeModel(for: handle, snapshot: snapshot))
        }

        torrents = models.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func makeModel(for handle: TorrentHandle, snapshot: TorrentHandle.Snapshot) -> TorrentTaskModel {
        TorrentTaskModel(
            id: handle.infoHashes.best.hex,
            name: snapshot.name.isEmpty ? "Unknown Torrent" : snapshot.name,
            state: snapshot.state,
            progress: snapshot.progress,
            downloadRate: Int64(snapshot.downloadRate),
            uploadRate: Int64(snapshot.uploadRate),
            total: Int64(snapshot.totalWanted),
            totalDone: Int64(snapshot.totalWantedDone),
            seeds: Int(snapshot.numberOfSeeds),
            peers: Int(snapshot.numberOfPeers),
            totalSeeds: Int(snapshot.numberOfTotalSeeds),
            totalPeers: Int(snapshot.numberOfTotalPeers),
            files: snapshot.files.map { file in
                TorrentFileItem(
                    index: file.index,
                    name: file.name,
                    size: Int64(file.size),
                    downloaded: Int64(file.downloaded),
                    priority: file.priority
                )
            },
            trackers: snapshot.trackers.map { tracker in
                TorrentTrackerItem(
                    url: tracker.trackerUrl,
                    state: tracker.state,
                    seeds: Int(tracker.seeds),
                    peers: Int(tracker.peers),
                    leeches: Int(tracker.leeches),
                    message: tracker.message
                )
            },
            magnetLink: snapshot.magnetLink,
            comment: snapshot.comment,
            creator: snapshot.creator,
            creationDate: snapshot.creationDate,
            isPaused: snapshot.isPaused,
            isSeed: snapshot.isSeed,
            isFinished: snapshot.isFinished
        )
    }

    private func handle(_ id: String) -> TorrentHandle? {
        if let cached = handlesByHash[id] {
            return cached
        }
        guard let session = session,
              let found = session.torrents.first(where: { $0.infoHashes.best.hex == id }) else {
            return nil
        }
        handlesByHash[id] = found
        return found
    }
}
