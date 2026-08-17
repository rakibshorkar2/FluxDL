import Foundation

/// Persists the app-level record of torrents the USER explicitly paused.
///
/// This is deliberately separate from LibTorrent's own pause state: the engine
/// also pauses torrents transiently because of queue constraints (Max Active /
/// Max Downloading / Max Uploading), and those queue-induced pauses must never
/// be recorded here. Only explicit user actions (`pauseTorrent`,
/// `pauseTorrents`, `pauseAll`) write to this store.
///
/// Torrents are identified by their stable info-hash hex string — never by
/// array indexes or display order. The record is cleared when a torrent is
/// deleted so a re-added torrent with the same info-hash starts with a clean
/// slate.
public final class TorrentManualPauseStore {

    public static let storageKey = "Torrent.ManuallyPausedHashes"

    private let defaults: UserDefaults
    private var pausedIDs: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pausedIDs = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    /// Whether the user explicitly paused the torrent with `id`.
    public func isPaused(_ id: String) -> Bool {
        pausedIDs.contains(id)
    }

    /// True when at least one torrent has an explicit manual-pause record.
    public var isEmpty: Bool {
        pausedIDs.isEmpty
    }

    /// All recorded info-hashes.
    public var recordedIDs: Set<String> {
        pausedIDs
    }

    /// Records an explicit user pause. Persists only when something changed.
    public func insert(_ id: String) {
        guard pausedIDs.insert(id).inserted else { return }
        persist()
    }

    /// Records a batch of explicit user pauses. Persists only when something changed.
    public func insert(_ ids: Set<String>) {
        let before = pausedIDs.count
        pausedIDs.formUnion(ids)
        if pausedIDs.count != before {
            persist()
        }
    }

    /// Clears the user's explicit pause intent for `id`. Persists only when
    /// something changed.
    public func remove(_ id: String) {
        guard pausedIDs.remove(id) != nil else { return }
        persist()
    }

    /// Clears the user's explicit pause intent for a batch of torrents.
    /// Persists only when something changed.
    public func remove(_ ids: Set<String>) {
        let before = pausedIDs.count
        pausedIDs.subtract(ids)
        if pausedIDs.count != before {
            persist()
        }
    }

    private func persist() {
        defaults.set(Array(pausedIDs), forKey: Self.storageKey)
    }
}
