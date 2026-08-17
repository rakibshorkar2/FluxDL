import Foundation
import Combine
import UserNotifications
import UIKit
import LibTorrent

/// Error surfaced by the torrent service. Carries a user-facing message.
public struct TorrentServiceError: LocalizedError {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// Engine-backed connection settings for the torrent session.
/// Every field maps to a real LibTorrent setting; nothing here is cosmetic.
public enum TorrentEncryptionOption: String, CaseIterable, Identifiable {
    case enabled = "Enabled"
    case forced = "Forced"
    case disabled = "Disabled"

    public var id: String { rawValue }
}

public struct TorrentConnectionSettings: Equatable {
    public var dhtEnabled: Bool
    public var lsdEnabled: Bool
    public var utpEnabled: Bool
    public var upnpEnabled: Bool
    public var natEnabled: Bool
    public var listenPort: Int
    public var preallocateStorage: Bool
    public var encryptionOption: TorrentEncryptionOption
    public var validateHttpsTrackers: Bool

    public static let defaultValue = TorrentConnectionSettings(
        dhtEnabled: true,
        lsdEnabled: true,
        utpEnabled: true,
        upnpEnabled: true,
        natEnabled: true,
        listenPort: 6881,
        preallocateStorage: false,
        encryptionOption: .enabled,
        validateHttpsTrackers: false
    )
}

/// Persists a stable `createdAt` timestamp per torrent, keyed by the stable
/// info-hash id. This is deliberately separate from the engine's own resume
/// data so the date survives engine-side changes, missing metadata dates and
/// fast-resume failures. Legacy epoch (1970) values are migrated away.
public final class TorrentRecordStore {
    private static let recordKey = "Torrent.Records.createdAt"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The earliest plausible torrent creation date: anything inside the first
    /// minute of the Unix epoch is treated as "no date" (epoch 0 renders as
    /// 1 Jan 1970, which is never a real torrent creation date).
    private static func isPlausibleDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970 > 60
    }

    public func createdAt(for id: String) -> Date? {
        guard let raw = defaults.object(forKey: Self.recordKey(id)) as? TimeInterval,
              raw.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: raw)
        return Self.isPlausibleDate(date) ? date : nil
    }

    /// Persists `date` for the torrent unless a better (plausible, older) one
    /// already exists. Never overwrites a valid existing record with a later date.
    public func registerCreatedAt(_ date: Date, for id: String) {
        guard Self.isPlausibleDate(date) else { return }
        if let existing = createdAt(for: id), existing <= date { return }
        defaults.set(date.timeIntervalSince1970, forKey: Self.recordKey(id))
    }

    /// Replaces an invalid/legacy epoch record with the provided date.
    public func migrateInvalidRecord(to date: Date, for id: String) {
        precondition(Self.isPlausibleDate(date), "Cannot migrate to an invalid date")
        defaults.set(date.timeIntervalSince1970, forKey: Self.recordKey(id))
    }

    public func removeRecord(for id: String) {
        defaults.removeObject(forKey: Self.recordKey(id))
    }

    private static func recordKey(_ id: String) -> String {
        "\(Self.recordKey).\(id)"
    }
}

/// Torrent engine wrapper around the LibTorrent framework.
/// Self-contained engine service for managing torrent tasks.
public final class TorrentService: NSObject, ObservableObject, SessionDelegate {

    public static let shared = TorrentService()

    // MARK: - Published State

    @Published public private(set) var torrents: [TorrentTaskModel] = []
    /// Placeholder models for torrents whose files are being deleted from disk.
    /// Kept alive until libtorrent reports that the deletion finished.
    @Published public private(set) var deletingTorrents: [TorrentTaskModel] = []
    @Published public private(set) var isSessionActive = false
    @Published public private(set) var lastErrorMessage: String?

    /// Session-global speed limits in bytes per second; 0 means unlimited.
    @Published public private(set) var globalDownloadSpeed: Int64
    @Published public private(set) var globalUploadSpeed: Int64
    /// Torrent queueing limits.
    @Published public private(set) var maxActiveTorrents: Int
    @Published public private(set) var maxDownloadingTorrents: Int
    @Published public private(set) var maxUploadingTorrents: Int
    @Published public var notificationsEnabled: Bool
    /// Connection-level settings that map 1:1 to LibTorrent settings.
    @Published public private(set) var connectionSettings: TorrentConnectionSettings

    // MARK: - Session

    public private(set) var session: Session?

    private var handlesByHash: [String: TorrentHandle] = [:]
    /// Info-hashes of torrents this process has removed. A queued engine
    /// callback (`didReceiveUpdateForTorrent`) for a removed torrent must
    /// never re-register its (now invalid) handle. Cleared when the torrent is
    /// genuinely re-added (`didAddTorrent`) or the session restarts.
    private var removedHashes: Set<String> = []
    private var stopSeedingByHash: Set<String> = []
    private var updateTimer: Timer?
    private var refreshInFlight = false
    private var refreshPending = false
    /// Deduplicates completion notifications (exactly once per torrent lifetime).
    private let completionTracker = TorrentCompletionTracker(storageKey: SettingsKey.notifiedCompletedHashes)
    /// Owns the torrent subsystem's background lifecycle (keep-alive claim +
    /// Live Activities). Attached after ServiceContainer construction so
    /// no static-init recursion occurs.
    private var backgroundManager: TorrentBackgroundManager?
    private let snapshotQueue = DispatchQueue(label: "FluxDL.TorrentService.snapshot", qos: .userInteractive)
    /// Serializes snapshot rounds against `session.removeTorrent(...)` so a
    /// TorrentHandle is never invalidated while a snapshot is using it.
    private let removalCoordinator = TorrentRemovalCoordinator()
    /// Deferred removals awaiting the in-flight snapshot round, keyed by the
    /// exact handle to remove. Only touched on the main thread.
    private var pendingRemovalHandles: [String: TorrentHandle] = [:]
    /// App-level record of torrents the user explicitly paused (distinct from
    /// queue-induced engine pauses). Survives app restarts and is reapplied
    /// during session restoration.
    public let manualPauseStore: TorrentManualPauseStore

    /// Records the moment a torrent is first seen here. Never resets.
    public let recordStore = TorrentRecordStore()
    /// Signed seconds since the last observed progress per torrent, keyed by id.
    /// Only touched on the main thread during publication.
    private var stalledSinceByID: [String: Date] = [:]
    /// A torrent counts as stalled only after this long without any progress
    /// while the engine reports it as downloading.
    private let stalledThreshold: TimeInterval = 45

    private enum SettingsKey {
        static let downloadSpeed = "Torrent.GlobalDownloadSpeed"
        static let uploadSpeed = "Torrent.GlobalUploadSpeed"
        static let maxActive = "Torrent.MaxActiveTorrents"
        static let maxDownloading = "Torrent.MaxDownloadingTorrents"
        static let maxUploading = "Torrent.MaxUploadingTorrents"
        static let notificationsEnabled = "Torrent.NotificationsEnabled"
        static let dhtEnabled = "Torrent.DHTEnabled"
        static let lsdEnabled = "Torrent.LSDEnabled"
        static let utpEnabled = "Torrent.UtpEnabled"
        static let upnpEnabled = "Torrent.UPNPEnabled"
        static let natEnabled = "Torrent.NATEnabled"
        static let listenPort = "Torrent.ListenPort"
        static let preallocateStorage = "Torrent.PreallocateStorage"
        static let encryptionOption = "Torrent.EncryptionOption"
        static let validateHttpsTrackers = "Torrent.ValidateHttpsTrackers"
        static let notifiedCompletedHashes = "Torrent.NotifiedCompletedHashes"
        static let manuallyPausedHashes = TorrentManualPauseStore.storageKey
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.manualPauseStore = TorrentManualPauseStore(defaults: defaults)
        self.globalDownloadSpeed = Int64(defaults.object(forKey: SettingsKey.downloadSpeed) as? Int ?? 0)
        self.globalUploadSpeed = Int64(defaults.object(forKey: SettingsKey.uploadSpeed) as? Int ?? 0)
        self.maxActiveTorrents = defaults.object(forKey: SettingsKey.maxActive) as? Int ?? 6
        self.maxDownloadingTorrents = defaults.object(forKey: SettingsKey.maxDownloading) as? Int ?? 4
        self.maxUploadingTorrents = defaults.object(forKey: SettingsKey.maxUploading) as? Int ?? 2
        self.notificationsEnabled = defaults.object(forKey: SettingsKey.notificationsEnabled) as? Bool ?? true

        let stored = TorrentConnectionSettings.defaultValue
        var connection = stored
        if let value = defaults.object(forKey: SettingsKey.dhtEnabled) as? Bool { connection.dhtEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.lsdEnabled) as? Bool { connection.lsdEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.utpEnabled) as? Bool { connection.utpEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.upnpEnabled) as? Bool { connection.upnpEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.natEnabled) as? Bool { connection.natEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.listenPort) as? Int, Self.isValidPort(value) { connection.listenPort = value }
        if let value = defaults.object(forKey: SettingsKey.preallocateStorage) as? Bool { connection.preallocateStorage = value }
        if let raw = defaults.string(forKey: SettingsKey.encryptionOption),
           let option = TorrentEncryptionOption(rawValue: raw) { connection.encryptionOption = option }
        if let value = defaults.object(forKey: SettingsKey.validateHttpsTrackers) as? Bool { connection.validateHttpsTrackers = value }
        self.connectionSettings = connection

        super.init()
    }

    /// Attaches the background lifecycle manager. Called exactly once by
    /// `ServiceContainer` after both this service and the manager exist.
    public func configureBackgroundLifecycle(_ manager: TorrentBackgroundManager) {
        backgroundManager = manager
    }

    // MARK: - Session Lifecycle

    public func startSession() {
        guard session == nil else { return }

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloads = documents.appendingPathComponent("Torrents", isDirectory: true)
        let torrentsDir = downloads.appendingPathComponent(".torrents", isDirectory: true)
        let fastResumeDir = downloads.appendingPathComponent(".fastresume", isDirectory: true)

        let settings = buildSessionSettings()

        let session = Session(
            downloads,
            torrentsPath: torrentsDir,
            fastResumePath: fastResumeDir,
            settings: settings,
            storages: [:]
        )
        session.add(self)
        self.session = session
        isSessionActive = true
        // Restored torrents must honor explicit user pauses from a previous
        // process lifetime. Applied before the first refresh so the very first
        // published snapshot already shows them paused. Queue-induced engine
        // pauses are never touched here — only recorded user intent is.
        removedHashes.removeAll()
        applyManualPauses(to: session)
        requestRefresh()

        if notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.requestRefresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// Tears the 1 Hz refresh timer down. Safe to call multiple times.
    /// Also tears the engine session down completely (the app only stops the
    /// session for tests/cleanup; production keeps it running for the process
    /// lifetime).
    public func stopSession() {
        refreshInFlight = false
        refreshPending = false
        updateTimer?.invalidate()
        updateTimer = nil
        removalCoordinator.reset()
        pendingRemovalHandles.removeAll()
        removedHashes.removeAll()
        handlesByHash.removeAll()
        torrents = []
        deletingTorrents = []
        session = nil
        isSessionActive = false
    }

    deinit {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    /// Builds a `Session.Settings` from the current persisted configuration.
    private func buildSessionSettings() -> Session.Settings {
        let connection = connectionSettings
        let settings = Session.Settings()
        settings.agentName = "FluxDL/1.0"
        settings.peerFingerprint = "-FD1000-"
        settings.maxDownloadSpeed = UInt(max(0, globalDownloadSpeed))
        settings.maxUploadSpeed = UInt(max(0, globalUploadSpeed))
        settings.maxActiveTorrents = maxActiveTorrents
        settings.maxDownloadingTorrents = maxDownloadingTorrents
        settings.maxUploadingTorrents = maxUploadingTorrents
        settings.isDhtEnabled = connection.dhtEnabled
        settings.isLsdEnabled = connection.lsdEnabled
        settings.isUtpEnabled = connection.utpEnabled
        settings.isUpnpEnabled = connection.upnpEnabled
        settings.isNatEnabled = connection.natEnabled
        settings.preallocateStorage = connection.preallocateStorage
        settings.validateHttpsTrackers = connection.validateHttpsTrackers
        switch connection.encryptionOption {
        case .enabled: settings.encryptionPolicy = .enabled
        case .forced: settings.encryptionPolicy = .forced
        case .disabled: settings.encryptionPolicy = .disabled
        }
        settings.port = connection.listenPort
        settings.portBindRetries = 5
        settings.listenInterfaces = "0.0.0.0:\(connection.listenPort)"
        settings.outgoingInterfaces = ""
        return settings
    }

    // MARK: - Connection Settings

    /// Applies a new connection configuration to the live session and persists it.
    public func updateConnectionSettings(_ newSettings: TorrentConnectionSettings) {
        var normalized = newSettings
        if !Self.isValidPort(normalized.listenPort) {
            normalized.listenPort = connectionSettings.listenPort
        }
        connectionSettings = normalized
        persistConnectionSettings(normalized)

        guard let session = session else { return }
        session.settings = buildSessionSettings()
        requestRefresh()
    }

    private func persistConnectionSettings(_ connection: TorrentConnectionSettings) {
        defaults.set(connection.dhtEnabled, forKey: SettingsKey.dhtEnabled)
        defaults.set(connection.lsdEnabled, forKey: SettingsKey.lsdEnabled)
        defaults.set(connection.utpEnabled, forKey: SettingsKey.utpEnabled)
        defaults.set(connection.upnpEnabled, forKey: SettingsKey.upnpEnabled)
        defaults.set(connection.natEnabled, forKey: SettingsKey.natEnabled)
        defaults.set(connection.listenPort, forKey: SettingsKey.listenPort)
        defaults.set(connection.preallocateStorage, forKey: SettingsKey.preallocateStorage)
        defaults.set(connection.encryptionOption.rawValue, forKey: SettingsKey.encryptionOption)
        defaults.set(connection.validateHttpsTrackers, forKey: SettingsKey.validateHttpsTrackers)
    }

    private static func isValidPort(_ port: Int) -> Bool {
        port >= 1024 && port <= 65535
    }

    // MARK: - Adding Torrents

    public func addMagnet(_ string: String, options: AddTorrentOptions = AddTorrentOptions()) -> Result<Void, TorrentServiceError> {
        guard let session = session else { return .failure(TorrentServiceError("Torrent session is not ready.")) }

        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned), url.scheme?.lowercased() == "magnet" else {
            return .failure(TorrentServiceError("Please enter a valid magnet link."))
        }
        guard let magnet = MagnetURI(with: url) else {
            return .failure(TorrentServiceError("Could not parse the magnet link."))
        }
        if let duplicate = duplicateError(for: magnet.infoHashes.best.hex) { return .failure(duplicate) }
        guard let handle = session.addTorrent(magnet) else {
            return .failure(TorrentServiceError("Failed to add the magnet link to the session."))
        }
        applyOptions(options, to: handle)
        return .success(())
    }

    public func addTorrentFile(at url: URL, options: AddTorrentOptions = AddTorrentOptions()) -> Result<Void, TorrentServiceError> {
        guard let session = session else { return .failure(TorrentServiceError("Torrent session is not ready.")) }

        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }

        guard let torrentFile = TorrentFile(with: url) else {
            return .failure(TorrentServiceError("Invalid or unsupported .torrent file."))
        }
        return addTorrent(torrentFile, options: options)
    }

    public func addTorrentFile(data: Data, options: AddTorrentOptions = AddTorrentOptions()) -> Result<Void, TorrentServiceError> {
        guard let torrentFile = TorrentFile(with: data) else {
            return .failure(TorrentServiceError("Invalid or unsupported .torrent file."))
        }
        return addTorrent(torrentFile, options: options)
    }

    public func addTorrent(_ torrentFile: TorrentFile, options: AddTorrentOptions = AddTorrentOptions()) -> Result<Void, TorrentServiceError> {
        guard let session = session else { return .failure(TorrentServiceError("Torrent session is not ready.")) }
        if let duplicate = duplicateError(for: torrentFile.infoHashes.best.hex) {
            return .failure(duplicate)
        }
        guard let handle = session.addTorrent(torrentFile) else {
            return .failure(TorrentServiceError("Failed to add the torrent file to the session."))
        }
        applyOptions(options, to: handle)
        return .success(())
    }

    private func duplicateError(for id: String) -> TorrentServiceError? {
        if handlesByHash[id] != nil || torrents.contains(where: { $0.id == id }) {
            return TorrentServiceError("This torrent is already in your list.")
        }
        return nil
    }

    /// Applies per-torrent options right after a torrent is added to the session.
    private func applyOptions(_ options: AddTorrentOptions, to handle: TorrentHandle) {
        let id = handle.infoHashes.best.hex
        if options.stopSeeding {
            stopSeedingByHash.insert(id)
            handle.setStopWhenReady(true)
        }
        if options.sequentialDownload {
            handle.setSequentialDownload(true)
        }
        if options.firstLastPiecePriority {
            handle.setFirstLastPriorityDownload(true)
        }
        if options.downloadLimit >= 0 {
            handle.setDownloadLimit(Int(options.downloadLimit))
        }
        if options.uploadLimit >= 0 {
            handle.setUploadLimit(Int(options.uploadLimit))
        }
    }

    // MARK: - Torrent Actions

    public func pauseTorrent(_ id: String) {
        guard let handle = handle(id) else { return }
        handle.pause()
        manualPauseStore.insert(id)
        requestRefresh()
    }

    public func resumeTorrent(_ id: String) {
        guard let handle = handle(id) else { return }
        handle.resume()
        manualPauseStore.remove(id)
        requestRefresh()
    }

    public func pauseTorrents(_ ids: [String]) {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }
        let paused = unique.filter { handle($0) != nil }
        paused.forEach { handle($0)?.pause() }
        manualPauseStore.insert(Set(paused))
        requestRefresh()
    }

    public func resumeTorrents(_ ids: [String]) {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }
        unique.forEach { handle($0)?.resume() }
        manualPauseStore.remove(Set(unique))
        requestRefresh()
    }

    public func rehashTorrent(_ id: String) { handle(id)?.rehash() }

    public func clearTorrentError(_ id: String) { handle(id)?.clearError() }

    public func removeTorrent(_ id: String, deleteFiles: Bool) {
        removeTorrents([id], deleteFiles: deleteFiles)
    }

    /// Removes a batch of torrents safely and coherently.
    ///
    /// The removal is coordinated with the snapshot pipeline: a TorrentHandle
    /// is never invalidated while a background snapshot operation is using it.
    /// Handles of targets that are part of the in-flight snapshot round are
    /// deferred (`TorrentRemovalCoordinator`); their `session.removeTorrent`
    /// calls run as one batch when the round completes. Targets outside the
    /// round are removed immediately. Either way, exactly one coherent refresh
    /// follows the batch, internal maps/sets are updated before any LibTorrent
    /// call, and a removed torrent can never be re-registered by a queued
    /// engine callback (tombstoned in `removedHashes`).
    public func removeTorrents(_ ids: [String], deleteFiles: Bool) {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }

        var needsRefresh = false
        for id in unique {
            guard let torrent = handle(id) else { continue }
            beginRemoval(of: id, deleteFiles: deleteFiles)
            if removalCoordinator.stageRemoval(id: id, deleteFiles: deleteFiles) {
                // The in-flight snapshot round still holds this handle; the
                // actual removal runs after the round completes.
                pendingRemovalHandles[id] = torrent
            } else {
                session?.removeTorrent(torrent, deleteFiles: deleteFiles)
                needsRefresh = true
            }
        }
        if needsRefresh {
            requestRefresh()
        }
    }

    /// Applies every bookkeeping side-effect of a removal immediately (UI
    /// state first, so the row vanishes instantly and a deletion placeholder
    /// appears when files are being deleted). The actual `session.removeTorrent`
    /// call happens either right away or after the in-flight snapshot round.
    private func beginRemoval(of id: String, deleteFiles: Bool) {
        if deleteFiles, let model = torrents.first(where: { $0.id == id }) {
            deletingTorrents.append(model)
            // Take the model out of the live list synchronously — otherwise
            // the same id briefly exists in both arrays and the list renders
            // duplicate-identity rows until the next refresh publishes.
            torrents.removeAll { $0.id == id }
        }
        removedHashes.insert(id)
        handlesByHash.removeValue(forKey: id)
        stopSeedingByHash.remove(id)
        stalledSinceByID.removeValue(forKey: id)
        recordStore.removeRecord(for: id)
        // A re-added torrent with the same info-hash must produce a fresh
        // completion notification even if its predecessor already fired.
        completionTracker.remove(id)
        // Deleting must clear the user's manual-pause intent so a re-added
        // torrent with the same info-hash starts with a clean slate.
        manualPauseStore.remove(id)
        backgroundManager?.torrentRemoved(id: id)
    }

    /// Performs the deferred removals after the in-flight snapshot round
    /// finished. Must be called on the main thread, in the round's completion.
    @discardableResult
    private func drainPendingRemovals() -> Bool {
        let removals = removalCoordinator.endSnapshotRound()
        guard !removals.isEmpty else { return false }
        for removal in removals {
            guard let torrent = pendingRemovalHandles.removeValue(forKey: removal.id) else { continue }
            session?.removeTorrent(torrent, deleteFiles: removal.deleteFiles)
        }
        return true
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

    public func setStopSeeding(_ id: String, enabled: Bool) {
        guard let handle = handle(id) else { return }
        if enabled {
            stopSeedingByHash.insert(id)
        } else {
            stopSeedingByHash.remove(id)
        }
        handle.setStopWhenReady(enabled)
    }

    /// Per-torrent speed limits. -1 means unlimited, 0 means no transfers.
    public func setDownloadLimit(_ id: String, bytesPerSecond: Int64) {
        handle(id)?.setDownloadLimit(Int(bytesPerSecond))
    }

    public func setUploadLimit(_ id: String, bytesPerSecond: Int64) {
        handle(id)?.setUploadLimit(Int(bytesPerSecond))
    }

    public func setSequentialDownload(_ id: String, enabled: Bool) {
        handle(id)?.setSequentialDownload(enabled)
    }

    public func setFirstLastPriorityDownload(_ id: String, enabled: Bool) {
        handle(id)?.setFirstLastPriorityDownload(enabled)
    }

    public func removeTracker(_ id: String, url: String) {
        handle(id)?.removeTrackers([url])
    }

    // MARK: - Global Settings

    /// Session-global speed limit in bytes per second; 0 means unlimited.
    public func setGlobalDownloadSpeed(_ bytesPerSecond: Int64) {
        let clamped = max(0, bytesPerSecond)
        globalDownloadSpeed = clamped
        defaults.set(Int(clamped), forKey: SettingsKey.downloadSpeed)
        session?.setDownloadSpeedLimit(Int(clamped))
    }

    public func setGlobalUploadSpeed(_ bytesPerSecond: Int64) {
        let clamped = max(0, bytesPerSecond)
        globalUploadSpeed = clamped
        defaults.set(Int(clamped), forKey: SettingsKey.uploadSpeed)
        session?.setUploadSpeedLimit(Int(clamped))
    }

    /// Applies and persists torrent queueing limits.
    public func setQueueLimits(maxActive: Int, maxDownloading: Int, maxUploading: Int) {
        let active = max(1, maxActive)
        let downloading = max(0, maxDownloading)
        let uploading = max(0, maxUploading)
        maxActiveTorrents = active
        maxDownloadingTorrents = downloading
        maxUploadingTorrents = uploading
        defaults.set(active, forKey: SettingsKey.maxActive)
        defaults.set(downloading, forKey: SettingsKey.maxDownloading)
        defaults.set(uploading, forKey: SettingsKey.maxUploading)
        session?.setMaxActiveTorrents(active, maxDownloading: downloading, maxUploading: uploading)
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: SettingsKey.notificationsEnabled)
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    public func pauseAll() {
        let present = Set(handlesByHash.keys)
        guard !present.isEmpty else { return }
        handlesByHash.values.forEach { $0.pause() }
        manualPauseStore.insert(present)
        requestRefresh()
    }

    public func resumeAll() {
        let present = Set(handlesByHash.keys)
        guard !present.isEmpty else { return }
        handlesByHash.values.forEach { $0.resume() }
        manualPauseStore.remove(present)
        requestRefresh()
    }

    // MARK: - SessionDelegate

    public func torrentManager(_ manager: Session, didAddTorrent torrent: TorrentHandle) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let hash = torrent.infoHashes.best.hex
            // The handle is genuinely live again (fresh add or re-add after a
            // deletion) — any earlier removal tombstone is stale.
            self.removedHashes.remove(hash)
            self.handlesByHash[hash] = torrent
            // A restored or re-added torrent must honor the user's recorded
            // manual pause intent (idempotent for torrents added pre-paused).
            self.restoreManualPauseIfNeeded(for: torrent)
            self.requestRefresh()
        }
    }

    public func torrentManager(_ manager: Session, didRemoveTorrentWithHash hashesData: TorrentHashes) {
        DispatchQueue.main.async { [weak self] in
            let id = hashesData.best.hex
            self?.handlesByHash.removeValue(forKey: id)
            self?.requestRefresh()
        }
    }

    public func torrentManager(_ manager: Session, didDeleteTorrentFilesForTorrentWithHash hashesData: TorrentHashes) {
        DispatchQueue.main.async { [weak self] in
            let id = hashesData.best.hex
            self?.deletingTorrents.removeAll { $0.id == id }
            self?.requestRefresh()
        }
    }

    public func torrentManager(_ manager: Session, didReceiveUpdateForTorrent torrent: TorrentHandle) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let id = torrent.infoHashes.best.hex
            // A queued update for a removed torrent must never re-register its
            // (now invalid) handle — doing so would let a later snapshot touch
            // a handle that was invalidated by `session.removeTorrent`.
            guard !self.removedHashes.contains(id),
                  !self.removalCoordinator.pendingRemovalIDs.contains(id) else {
                return
            }
            self.handlesByHash[id] = torrent
            self.restoreManualPauseIfNeeded(for: torrent)
            self.requestRefresh()
        }
    }

    public func torrentManager(_ manager: Session, didErrorOccur error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Snapshot Publishing

    /// Coalesced refresh: snapshot collection runs on a background queue,
    /// only the final model array is published on the main thread. A refresh
    /// requested while one is in flight is re-run afterwards instead of being
    /// dropped, so user actions are never lost.
    ///
    /// Removals are coordinated with this pipeline: the exact set of hashes
    /// being snapshotted is announced to `removalCoordinator` before the
    /// snapshot work is dispatched (both on the main thread), so any removal
    /// of a torrent in that set is deferred until the round completes. The
    /// round's completion then drains the deferred batch via
    /// `session.removeTorrent(...)` and requests one coherent follow-up
    /// refresh. A TorrentHandle is therefore never invalidated while a
    /// background snapshot is accessing it.
    private func requestRefresh() {
        guard let session = session else { return }
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        refreshInFlight = true

        var currentHashes: Set<String> = []
        for handle in session.torrents {
            let hash = handle.infoHashes.best.hex
            // Never resurrect a removed torrent from the session's list.
            guard !removedHashes.contains(hash) else { continue }
            currentHashes.insert(hash)
            if handlesByHash[hash] == nil {
                handlesByHash[hash] = handle
            }
        }
        if handlesByHash.keys.count != currentHashes.count {
            handlesByHash = handlesByHash.filter { currentHashes.contains($0.key) }
        }

        let handles = Array(handlesByHash.values)
        guard !handles.isEmpty else {
            removalCoordinator.beginSnapshotRound([])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stalledSinceByID.removeAll()
                self.torrents = []
                let drained = self.drainPendingRemovals()
                self.refreshInFlight = false
                if self.refreshPending || drained {
                    self.refreshPending = false
                    self.requestRefresh()
                }
            }
            return
        }

        removalCoordinator.beginSnapshotRound(Set(handles.map { $0.infoHashes.best.hex }))
        let stopSeeding = stopSeedingByHash
        snapshotQueue.async { [weak self] in
            guard let self = self else { return }

            var models: [TorrentTaskModel] = []
            for handle in handles {
                handle.updateSnapshot()
                let snapshot = handle.snapshot
                guard snapshot.isValid else { continue }
                models.append(self.makeModel(for: handle, snapshot: snapshot, stopSeeding: stopSeeding))
            }
            let sorted = models.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            DispatchQueue.main.async {
                // Discard snapshots of torrents whose removal is already in
                // flight: a removed torrent must never reappear in the live
                // list (not even for one publish round).
                let pendingIDs = self.removalCoordinator.pendingRemovalIDs
                let filtered = sorted.filter { !pendingIDs.contains($0.id) }
                let withStallState = self.applyStallState(to: filtered)
                self.torrents = withStallState
                self.checkForCompletions(withStallState)
                // Drives background keep-alive + Live Activities. No-op in the
                // foreground (keep-alive claim stays released, activities
                // already ended by handleAppForegrounding).
                self.backgroundManager?.update(with: withStallState)

                // The round is over: deferred removals can now run safely.
                let drained = self.drainPendingRemovals()
                self.refreshInFlight = false
                if self.refreshPending || drained {
                    self.refreshPending = false
                    self.requestRefresh()
                }
            }
        }
    }

    private func makeModel(for handle: TorrentHandle, snapshot: TorrentHandle.Snapshot, stopSeeding: Set<String>) -> TorrentTaskModel {
        let id = handle.infoHashes.best.hex
        let remaining = snapshot.totalWantedDone < snapshot.totalWanted
            ? snapshot.totalWanted - snapshot.totalWantedDone
            : 0
        let eta: TimeInterval? = remaining > 0 && snapshot.downloadRate > 0
            ? TimeInterval(remaining) / TimeInterval(snapshot.downloadRate)
            : nil
        let currentState: TorrentHandle.State = snapshot.isPaused ? .paused : snapshot.state

        let metadataDate = snapshot.creationDate
        let engineAddedDate = snapshot.addedDate
        let createdAt = resolveCreatedAt(for: id, metadataDate: metadataDate, engineAddedDate: engineAddedDate)

        return TorrentTaskModel(
            id: id,
            name: snapshot.name.isEmpty ? "Unknown Torrent" : snapshot.name,
            state: currentState,
            progress: snapshot.progress,
            downloadRate: Int64(snapshot.downloadRate),
            uploadRate: Int64(snapshot.uploadRate),
            eta: eta,
            downloadLimit: Int64(snapshot.downloadLimit),
            uploadLimit: Int64(snapshot.uploadLimit),
            total: Int64(snapshot.totalWanted),
            totalDone: Int64(snapshot.totalWantedDone),
            totalDownload: Int64(snapshot.totalDownload),
            totalUpload: Int64(snapshot.totalUpload),
            seeds: Int(snapshot.numberOfSeeds),
            peers: Int(snapshot.numberOfPeers),
            leechers: Int(snapshot.numberOfLeechers),
            totalSeeds: Int(snapshot.numberOfTotalSeeds),
            totalPeers: Int(snapshot.numberOfTotalPeers),
            totalLeechers: Int(snapshot.numberOfTotalLeechers),
            files: snapshot.files.map { file in
                TorrentFileItem(
                    index: Int(file.index),
                    name: file.name,
                    size: Int64(file.size),
                    downloaded: Int64(file.downloaded),
                    priority: file.priority
                )
            },
            trackers: snapshot.trackers.map { tracker in
                let nextAnnounce = Self.usableAnnounceDate(tracker.nextAnnounceTime)
                return TorrentTrackerItem(
                    url: tracker.trackerUrl,
                    state: tracker.state,
                    seeds: Int(tracker.seeds),
                    peers: Int(tracker.peers),
                    leeches: Int(tracker.leeches),
                    downloaded: Int(tracker.downloaded),
                    nextAnnounceTime: nextAnnounce,
                    message: tracker.message?.isEmpty == false ? tracker.message : nil
                )
            },
            magnetLink: snapshot.magnetLink.isEmpty ? nil : snapshot.magnetLink,
            comment: snapshot.comment?.isEmpty == false ? snapshot.comment : nil,
            creator: snapshot.creator?.isEmpty == false ? snapshot.creator : nil,
            creationDate: metadataDate,
            addedDate: engineAddedDate,
            createdAt: createdAt,
            downloadPath: snapshot.downloadPath?.path,
            pieceLength: Int(snapshot.pieceLength),
            pieceCount: Int(snapshot.pieceCount),
            isStalled: false,
            isPaused: snapshot.isPaused,
            isSeed: snapshot.isSeed,
            isFinished: snapshot.isFinished,
            stopSeeding: stopSeeding.contains(id),
            isSequential: snapshot.isSequential,
            isFirstLastPiecePriority: snapshot.isFirstLastPiecePriority
        )
    }

    /// Next-announce times that are past, absurdly far away, or unreliable are
    /// reported as nil rather than presented as facts.
    private static func usableAnnounceDate(_ date: Date?) -> Date? {
        guard let date = date else { return nil }
        let interval = date.timeIntervalSinceNow
        guard interval.isFinite, interval > 10, interval < 60 * 60 * 24 * 7 else { return nil }
        return date
    }

    // MARK: - Stable createdAt

    /// Resolves the stable creation timestamp for a torrent.
    ///
    /// Migration order for records that are missing or stuck at epoch 0:
    /// 1. valid torrent metadata creation date
    /// 2. the engine's persisted added/imported date
    /// 3. current date as the final fallback
    ///
    /// Once a plausible record exists it is returned unchanged, so the date
    /// survives restarts, pause/resume, rechecks and moves.
    private func resolveCreatedAt(for id: String, metadataDate: Date?, engineAddedDate: Date?) -> Date {
        if let persisted = recordStore.createdAt(for: id) {
            return persisted
        }
        let replacement = metadataDate
            ?? engineAddedDate
            ?? Date()
        recordStore.migrateInvalidRecord(to: replacement, for: id)
        return replacement
    }

    // MARK: - Stalled Detection

    /// Derives the stalled presentation state from continuous observation.
    private func applyStallState(to models: [TorrentTaskModel]) -> [TorrentTaskModel] {
        let now = Date()
        var updated = models
        var currentIDs = Set<String>()

        for index in models.indices {
            let model = models[index]
            currentIDs.insert(model.id)
            var copy = model

            let isCandidate = model.state == .downloading
                && !model.isPaused
                && model.state != .storageError
                && model.remainingBytes > 0
                && model.downloadRate <= 0

            if isCandidate {
                let since = stalledSinceByID[model.id] ?? now
                stalledSinceByID[model.id] = since
                copy.isStalled = now.timeIntervalSince(since) >= stalledThreshold
            } else {
                stalledSinceByID.removeValue(forKey: model.id)
                copy.isStalled = false
            }
            updated[index] = copy
        }

        stalledSinceByID = stalledSinceByID.filter { currentIDs.contains($0.key) }
        return updated
    }

    // MARK: - App Lifecycle & Keep-Alive Integration

    public func handleAppBackgrounding() {
        backgroundManager?.handleAppBackgrounding(torrents: torrents)
    }

    public func handleAppForegrounding() {
        // App in foreground natively maintains process execution thread.
        backgroundManager?.handleAppForegrounding()
    }

    // MARK: - Completion Notifications

    /// Notifies exactly once per torrent when it transitions to a finished/seeding
    /// state. Already-complete torrents observed on the first refresh after
    /// launch (e.g. restored from fast-resume data) are absorbed silently —
    /// the completion predates this process, so notifying would be a false
    /// "just finished" event.
    private func checkForCompletions(_ models: [TorrentTaskModel]) {
        guard notificationsEnabled else {
            return
        }
        if !completionTracker.isBaselineEstablished {
            completionTracker.establishBaseline(with: models.filter { $0.isSeed || $0.isFinished }.map(\.id))
            return
        }
        for model in models where model.isSeed || model.isFinished {
            if completionTracker.noteCompleted(model.id) {
                postCompletionNotification(for: model)
            }
        }
    }

    private func postCompletionNotification(for model: TorrentTaskModel) {
        let content = UNMutableNotificationContent()
        content.title = "Torrent Download Complete"
        content.body = "\(model.name) has finished downloading."
        content.sound = .default
        content.userInfo = ["torrentId": model.id, "type": "torrent"]
        let request = UNNotificationRequest(
            identifier: "FluxDL.torrent.complete.\(model.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Manual Pause Persistence

    /// Whether the user explicitly paused this torrent (persisted app-level
    /// record — distinct from queue-induced engine pauses).
    public func isManuallyPaused(_ id: String) -> Bool {
        manualPauseStore.isPaused(id)
    }

    /// Re-applies recorded user pauses to the torrents currently in `session`.
    /// Called as early as safely possible during session restoration, before
    /// the first refresh, so a manually paused torrent can never be observed
    /// actively downloading after an app restart.
    private func applyManualPauses(to session: Session) {
        guard !manualPauseStore.isEmpty else { return }
        for handle in session.torrents {
            restoreManualPauseIfNeeded(for: handle)
        }
    }

    /// Pauses `torrent` when the user explicitly paused it. Idempotent.
    private func restoreManualPauseIfNeeded(for torrent: TorrentHandle) {
        guard manualPauseStore.isPaused(torrent.infoHashes.best.hex) else { return }
        torrent.pause()
    }

    private func handle(_ id: String) -> TorrentHandle? {
        if let cached = handlesByHash[id] {
            return cached
        }
        guard !removedHashes.contains(id),
              let session = session,
              let found = session.torrents.first(where: { $0.infoHashes.best.hex == id }) else {
            return nil
        }
        handlesByHash[id] = found
        return found
    }
}