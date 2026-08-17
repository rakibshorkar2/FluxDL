import Foundation

/// One deferred removal request: the info-hash to remove and whether its
/// files must be deleted from disk.
public struct PendingTorrentRemoval: Equatable {
    public let id: String
    public let deleteFiles: Bool

    public init(id: String, deleteFiles: Bool) {
        self.id = id
        self.deleteFiles = deleteFiles
    }
}

/// Deterministic synchronization between the snapshot pipeline and torrent
/// removal, without sleeps or error suppression.
///
/// Invariant enforced here:
///
///     A TorrentHandle is never invalidated while a background snapshot
///     operation is actively accessing it.
///
/// The snapshot pipeline snapshots a fixed set of info-hashes per round.
/// `TorrentService` announces that set with `beginSnapshotRound` before it
/// dispatches snapshot work to `snapshotQueue` (all of this happens on the
/// main thread, so there is no data race on the coordinator itself). Any
/// removal staged while a round is active is recorded as *deferred*; the
/// actual `session.removeTorrent(...)` calls are made by the service only
/// after `endSnapshotRound()` returns the deferred batch — at which point no
/// snapshot work can touch those handles anymore (the snapshot queue is
/// serial and the in-flight round has already finished).
///
/// All state is touched only from the main thread (the service's snapshot
/// dispatch site and completion sites), so this type is intentionally not
/// itself thread-safe.
public final class TorrentRemovalCoordinator {

    /// Info-hashes being snapshotted by the currently in-flight round.
    private var activeSnapshotHashes: Set<String> = []
    /// Removals deferred until the in-flight round completes.
    private var pendingRemovals: [PendingTorrentRemoval] = []

    /// Whether any removal is currently deferred.
    public var hasPendingRemovals: Bool { !pendingRemovals.isEmpty }

    /// Info-hashes with a deferred removal. Used to filter a completed round's
    /// models out of publication so a removed torrent never reappears in the
    /// live list while its removal is still queued.
    public var pendingRemovalIDs: Set<String> {
        Set(pendingRemovals.map(\.id))
    }

    /// Whether `id` is being touched by the in-flight snapshot round.
    public func isBeingSnapshotted(_ id: String) -> Bool {
        activeSnapshotHashes.contains(id)
    }

    /// Starts a new snapshot round over exactly `hashes`. Any removal staged
    /// for one of these hashes is deferred until `endSnapshotRound()`.
    public func beginSnapshotRound(_ hashes: Set<String>) {
        activeSnapshotHashes = hashes
    }

    /// Stages a removal for `id`.
    ///
    /// - Returns: `true` when the removal was deferred (a snapshot round is
    ///   actively touching the handle); `false` when the caller may remove the
    ///   handle from the session immediately.
    public func stageRemoval(id: String, deleteFiles: Bool) -> Bool {
        guard activeSnapshotHashes.contains(id) else { return false }
        pendingRemovals.append(PendingTorrentRemoval(id: id, deleteFiles: deleteFiles))
        return true
    }

    /// Completes the in-flight snapshot round.
    ///
    /// - Returns: the batch of deferred removals that is now safe to perform
    ///   (no snapshot work can be using those handles anymore).
    public func endSnapshotRound() -> [PendingTorrentRemoval] {
        activeSnapshotHashes = []
        let drained = pendingRemovals
        pendingRemovals = []
        return drained
    }

    /// Clears all state (used when the session is torn down).
    public func reset() {
        activeSnapshotHashes = []
        pendingRemovals = []
    }
}
