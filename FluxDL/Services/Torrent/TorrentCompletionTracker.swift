import Foundation

/// Deduplicates torrent completion notifications.
///
/// A torrent must produce EXACTLY ONE completion notification per lifetime.
/// The set of already-notified info-hashes is persisted to UserDefaults so
/// the guarantee survives engine refreshes, pause/resume cycles, app
/// backgrounds/foregrounds, process relaunches and session restarts.
///
/// Baseline semantics: the first time a session observes a torrent that is
/// already complete (e.g. restored from fast-resume data), it is absorbed
/// silently — the completion happened before this process could observe it,
/// so notifying would be a false "just finished" event.
public final class TorrentCompletionTracker {

    private let defaults: UserDefaults
    private let storageKey: String
    private var notifiedHashes: Set<String>
    private var hasEstablishedBaseline = false

    public init(defaults: UserDefaults = .standard, storageKey: String) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.notifiedHashes = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// True when this torrent is completing for the first time since the
    /// baseline was established — the caller should fire the notification.
    /// Always records the hash and persists when a notification fires, so a
    /// later poll cycle can never produce a duplicate.
    public func noteCompleted(_ id: String) -> Bool {
        let shouldFire = hasEstablishedBaseline && !notifiedHashes.contains(id)
        notifiedHashes.insert(id)
        if shouldFire {
            persist()
        }
        return shouldFire
    }

    /// Absorbs already-complete torrents without notifying. Called once per
    /// process lifetime, on the first refresh after launch.
    public func establishBaseline(with completedIDs: [String]) {
        guard !hasEstablishedBaseline else { return }
        hasEstablishedBaseline = true
        var changed = false
        for id in completedIDs where !notifiedHashes.contains(id) {
            notifiedHashes.insert(id)
            changed = true
        }
        if changed {
            persist()
        }
    }

    /// Called when a torrent is removed so a re-added torrent with the same
    /// info-hash can fire a fresh completion notification.
    public func remove(_ id: String) {
        notifiedHashes.remove(id)
        persist()
    }

    public var isBaselineEstablished: Bool { hasEstablishedBaseline }

    /// Test-observable: whether a hash has already been marked notified.
    public func contains(_ id: String) -> Bool { notifiedHashes.contains(id) }

    private func persist() {
        defaults.set(Array(notifiedHashes), forKey: storageKey)
    }
}