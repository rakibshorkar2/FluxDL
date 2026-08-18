import XCTest
@testable import FluxDL

/// Tests for the Torrent subsystem fixes:
/// 1. snapshot/removal synchronization (no invalid-handle races, coherent
///    batch deletion)
/// 2. persisted user-manual pause state (survives session restart, never
///    confused with queue-induced engine pauses)
/// 3. edit mode closing after delete
/// 4. Browser → Torrent integration (magnet + .torrent metadata through the
///    public TorrentService API)
final class TorrentServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Fresh, isolated UserDefaults suite + service with a randomized listen
    /// port so tests never collide with each other or a live app session.
    @MainActor
    private func makeIsolatedService() -> TorrentService {
        let suiteName = "TorrentServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = TorrentService(defaults: defaults)
        var settings = TorrentConnectionSettings.defaultValue
        settings.listenPort = Int.random(in: 7000..<8000)
        service.updateConnectionSettings(settings)
        service.setNotificationsEnabled(false)
        return service
    }

    /// Polls a condition while pumping the run loop so async service
    /// callbacks (snapshot round completions, delegate notifications) fire.
    @discardableResult
    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Minimal but valid single-file bencode torrent. The info-hash depends on
    /// the encoded `name`, so distinct names yield distinct torrents.
    private static func makeMinimalTorrentData(name: String) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        append("d8:announce29:http://x.example.com/announce4:infod6:lengthi1e4:name\(name.count):\(name)12:piece lengthi16384e6:pieces20:")
        data.append(Data(repeating: 65, count: 20))
        append("ee")
        return data
    }

    private static let testHash = "0123456789abcdef0123456789abcdef01234567"

    // MARK: - TorrentRemovalCoordinator (snapshot/removal synchronization)

    /// A removal outside an active snapshot round is immediate (not deferred).
    func testRemovalOutsideActiveRoundIsImmediate() {
        let coordinator = TorrentRemovalCoordinator()
        XCTAssertFalse(coordinator.stageRemoval(id: "A", deleteFiles: false))
        XCTAssertFalse(coordinator.hasPendingRemovals)
        XCTAssertTrue(coordinator.pendingRemovalIDs.isEmpty)
    }

    /// A removal inside an active snapshot round is deferred and tracked.
    func testRemovalInsideActiveRoundIsDeferred() {
        let coordinator = TorrentRemovalCoordinator()
        coordinator.beginSnapshotRound(["A", "B", "C"])

        XCTAssertTrue(coordinator.isBeingSnapshotted("B"))
        XCTAssertFalse(coordinator.isBeingSnapshotted("D"))

        XCTAssertTrue(coordinator.stageRemoval(id: "B", deleteFiles: true))
        XCTAssertTrue(coordinator.hasPendingRemovals)
        XCTAssertEqual(coordinator.pendingRemovalIDs, ["B"])
    }

    /// The deferred batch is drained exactly once when the round ends, and
    /// only then — never while the round is active.
    func testEndSnapshotRoundDrainsPendingExactlyOnce() {
        let coordinator = TorrentRemovalCoordinator()
        coordinator.beginSnapshotRound(["A", "B", "C"])
        XCTAssertTrue(coordinator.stageRemoval(id: "A", deleteFiles: false))
        XCTAssertTrue(coordinator.stageRemoval(id: "C", deleteFiles: true))

        // The round is still active: nothing may be drained yet.
        XCTAssertTrue(coordinator.hasPendingRemovals)

        let drained = coordinator.endSnapshotRound()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(Set(drained.map(\.id)), ["A", "C"])
        XCTAssertEqual(Set(drained.map(\.deleteFiles)), [true])
        XCTAssertFalse(coordinator.hasPendingRemovals)
        XCTAssertTrue(coordinator.pendingRemovalIDs.isEmpty)
        XCTAssertFalse(coordinator.isBeingSnapshotted("A"))

        // A second drain yields nothing.
        XCTAssertTrue(coordinator.endSnapshotRound().isEmpty)
    }

    /// A removal staged during one round survives into the next round and is
    /// only drained at that round's end.
    func testDeferredRemovalSurvivesRoundReplacement() {
        let coordinator = TorrentRemovalCoordinator()
        coordinator.beginSnapshotRound(["A"])
        XCTAssertTrue(coordinator.stageRemoval(id: "A", deleteFiles: false))

        coordinator.beginSnapshotRound(["B"])
        XCTAssertFalse(coordinator.isBeingSnapshotted("A"))
        XCTAssertTrue(coordinator.hasPendingRemovals, "deferred removal must not be lost")

        let drained = coordinator.endSnapshotRound()
        XCTAssertEqual(drained.map(\.id), ["A"])
    }

    /// Reset clears active round and deferred removals (session teardown).
    func testResetClearsEverything() {
        let coordinator = TorrentRemovalCoordinator()
        coordinator.beginSnapshotRound(["A"])
        _ = coordinator.stageRemoval(id: "A", deleteFiles: true)
        coordinator.reset()

        XCTAssertFalse(coordinator.hasPendingRemovals)
        XCTAssertTrue(coordinator.pendingRemovalIDs.isEmpty)
        XCTAssertFalse(coordinator.isBeingSnapshotted("A"))
    }

    /// Cancelling a deferred removal removes it from the batch; the round
    /// ends with only the remaining removals drained.
    func testCancelRemovalRemovesPendingEntry() {
        let coordinator = TorrentRemovalCoordinator()
        coordinator.beginSnapshotRound(["A", "B"])
        XCTAssertTrue(coordinator.stageRemoval(id: "A", deleteFiles: false))
        XCTAssertTrue(coordinator.stageRemoval(id: "B", deleteFiles: true))

        XCTAssertTrue(coordinator.cancelRemoval(id: "A"))
        XCTAssertFalse(coordinator.cancelRemoval(id: "A"), "already cancelled")
        XCTAssertEqual(coordinator.pendingRemovalIDs, ["B"])

        let drained = coordinator.endSnapshotRound()
        XCTAssertEqual(drained.map(\.id), ["B"])
        XCTAssertTrue(drained.first?.deleteFiles == true)
    }

    /// Cancelling an id with no pending removal is a no-op.
    func testCancelRemovalNoOpWhenNotPending() {
        let coordinator = TorrentRemovalCoordinator()
        XCTAssertFalse(coordinator.cancelRemoval(id: "A"))

        coordinator.beginSnapshotRound(["A"])
        XCTAssertFalse(coordinator.cancelRemoval(id: "A"), "not staged yet")
        XCTAssertFalse(coordinator.cancelRemoval(id: "Z"), "unknown id")
        XCTAssertTrue(coordinator.pendingRemovalIDs.isEmpty)
    }

    // MARK: - TorrentManualPauseStore

    /// Explicit pause records survive store reinstantiation (app restart).
    func testManualPauseSurvivesReinstantiation() {
        let suite = "TorrentServiceTests.pausePersist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = TorrentManualPauseStore(defaults: defaults)
        XCTAssertFalse(store.isPaused("A"))
        store.insert("A")
        store.insert("B")
        XCTAssertTrue(store.isPaused("A"))
        XCTAssertTrue(store.isPaused("B"))

        // New instance over the same defaults — like a fresh process.
        let reloaded = TorrentManualPauseStore(defaults: defaults)
        XCTAssertTrue(reloaded.isPaused("A"))
        XCTAssertEqual(reloaded.recordedIDs, ["A", "B"])

        reloaded.remove("A")
        let reloadedAgain = TorrentManualPauseStore(defaults: defaults)
        XCTAssertFalse(reloadedAgain.isPaused("A"))
        XCTAssertTrue(reloadedAgain.isPaused("B"))
    }

    /// Resume / delete clear the record; removing an absent id is a no-op.
    func testManualPauseRemoveClearsRecord() {
        let suite = "TorrentServiceTests.pauseRemove.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = TorrentManualPauseStore(defaults: defaults)
        store.insert("A")
        store.remove("A")
        XCTAssertFalse(store.isPaused("A"))
        store.remove("A") // no crash, no record
        XCTAssertTrue(store.isEmpty)
    }

    /// Batch pause / batch resume update the record as a set.
    func testManualPauseBatchOperations() {
        let suite = "TorrentServiceTests.pauseBatch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = TorrentManualPauseStore(defaults: defaults)
        store.insert(["A", "B", "C"])
        XCTAssertEqual(store.recordedIDs, ["A", "B", "C"])

        store.remove(["B", "C"])
        XCTAssertTrue(store.isPaused("A"))
        XCTAssertFalse(store.isPaused("B"))
        XCTAssertFalse(store.isPaused("C"))
    }

    /// Queue-induced engine pauses are never written to the store: a store
    /// that was never explicitly told about a pause has no records.
    func testQueuePausedTorrentNeverRecorded() {
        let suite = "TorrentServiceTests.pauseQueue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = TorrentManualPauseStore(defaults: defaults)
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(store.isPaused("queue-paused-hash"))

        // Nothing was persisted by mere observation.
        let reloaded = TorrentManualPauseStore(defaults: defaults)
        XCTAssertTrue(reloaded.isEmpty)
    }

    // MARK: - Edit mode after delete (TorrentViewModel)

    /// Batch remove (keep files) always leaves edit mode and clears the
    /// selection — even though other torrents remain.
    @MainActor
    func testRemoveSelectedExitsEditModeKeepFiles() {
        let service = makeIsolatedService()
        let viewModel = TorrentViewModel(service: service)

        viewModel.enterEditMode()
        viewModel.toggleSelection("A")
        viewModel.toggleSelection("B")
        XCTAssertTrue(viewModel.isEditing)

        viewModel.removeSelected(deleteFiles: false)

        XCTAssertFalse(viewModel.isEditing, "edit mode must close after a valid batch delete")
        XCTAssertTrue(viewModel.selectedIDs.isEmpty, "selection must be cleared")
    }

    /// Batch remove (delete files) behaves identically.
    @MainActor
    func testRemoveSelectedExitsEditModeDeleteFiles() {
        let service = makeIsolatedService()
        let viewModel = TorrentViewModel(service: service)

        viewModel.enterEditMode()
        viewModel.toggleSelection("A")
        viewModel.removeSelected(deleteFiles: true)

        XCTAssertFalse(viewModel.isEditing)
        XCTAssertTrue(viewModel.selectedIDs.isEmpty)
    }

    /// Selecting 2 of several torrents and removing them still closes the
    /// edit action bar (the old code only closed it when the list emptied).
    @MainActor
    func testRemoveSelectedWithPartialSelectionExitsEditMode() {
        let service = makeIsolatedService()
        let viewModel = TorrentViewModel(service: service)

        viewModel.enterEditMode()
        viewModel.toggleSelection("A")
        viewModel.toggleSelection("B")
        viewModel.removeSelected(deleteFiles: false)

        XCTAssertFalse(viewModel.isEditing)
        XCTAssertTrue(viewModel.selectedIDs.isEmpty)
    }

    /// Removing the last selected torrent (single-item path) exits edit mode.
    @MainActor
    func testRemoveExitsEditModeWhenSelectionEmpties() {
        let service = makeIsolatedService()
        let viewModel = TorrentViewModel(service: service)

        viewModel.enterEditMode()
        viewModel.toggleSelection("A")
        viewModel.remove("A", deleteFiles: false)

        XCTAssertFalse(viewModel.isEditing)
        XCTAssertTrue(viewModel.selectedIDs.isEmpty)
    }

    /// Edit mode stays active while the selection still contains torrents.
    @MainActor
    func testEditModeStaysActiveWhileSelectionRemains() {
        let service = makeIsolatedService()
        let viewModel = TorrentViewModel(service: service)

        viewModel.enterEditMode()
        viewModel.toggleSelection("A")
        viewModel.toggleSelection("B")
        viewModel.remove("A", deleteFiles: false)

        XCTAssertTrue(viewModel.isEditing, "edit mode must stay while other torrents are selected")
        XCTAssertEqual(viewModel.selectedIDs, ["B"])
    }

    /// Undo re-adds a keep-files removal through the public API: the toast is
    /// presented on removal, the torrent leaves the live list, and undo brings
    /// it back (either by cancelling the deferred removal or by magnet
    /// re-add — both must converge on the torrent returning).
    @MainActor
    func testUndoRemovalBringsTorrentBack() {
        let service = makeIsolatedService()
        let viewModel = TorrentViewModel(service: service)
        defer { service.stopSession() }

        service.startSession()
        XCTAssertNil(viewModel.addMagnet("magnet:?xt=urn:btih:\(Self.testHash)&dn=Undo"))
        XCTAssertTrue(poll { service.torrents.count == 1 })
        let id = service.torrents[0].id

        viewModel.remove(id, deleteFiles: false)
        XCTAssertNotNil(viewModel.undoToast, "keep-files removal must offer undo")
        XCTAssertTrue(poll { service.torrents.isEmpty }, "removal must commit")
        // Undo becomes actionable once the removal is committed (or still
        // cancellable): tapping earlier would false-fail on the duplicate
        // check, so the button stays disabled until this is true.
        XCTAssertTrue(poll { viewModel.canUndoCurrentToast }, "undo must become available")

        viewModel.undoRemoval()
        XCTAssertNil(viewModel.undoToast, "undo consumes the toast")

        XCTAssertTrue(
            poll { service.torrents.contains { $0.id == id } },
            "undo must bring the torrent back into the live list"
        )
        XCTAssertFalse(service.isManuallyPaused(id), "re-added torrent must start with a clean slate")

        service.removeTorrent(id, deleteFiles: false)
        XCTAssertTrue(poll { service.torrents.isEmpty })
    }

    // MARK: - Browser integration (public API surface)

    /// A magnet link can be added through the public API once the session is
    /// active and becomes a live torrent in `torrents` (no restart needed).
    @MainActor
    func testAddMagnetProducesLiveTorrent() {
        let service = makeIsolatedService()
        defer { service.stopSession() }

        service.startSession()
        XCTAssertTrue(service.isSessionActive)

        let result = service.addMagnet("magnet:?xt=urn:btih:\(Self.testHash)&dn=Test")
        if case .failure(let error) = result {
            XCTFail("magnet add failed: \(error.localizedDescription)")
        }

        XCTAssertTrue(
            poll { service.torrents.contains { $0.id == Self.testHash } },
            "the magnet must appear in the live torrent list"
        )
        // The session is fresh: no stale manual-pause record for this hash.
        XCTAssertFalse(service.isManuallyPaused(Self.testHash))

        service.removeTorrent(Self.testHash, deleteFiles: false)
    }

    /// Remote `.torrent` metadata (bytes) is added through the public API and
    /// starts according to engine rules with no stale pause record.
    @MainActor
    func testAddTorrentFileDataProducesLiveTorrent() {
        let service = makeIsolatedService()
        defer { service.stopSession() }

        service.startSession()
        let data = Self.makeMinimalTorrentData(name: "ts-add-file")
        let result = service.addTorrentFile(data: data)
        if case .failure(let error) = result {
            XCTFail("torrent add failed: \(error.localizedDescription)")
        }

        XCTAssertTrue(
            poll { !service.torrents.isEmpty },
            "the torrent must appear in the live torrent list"
        )
        let id = service.torrents[0].id
        XCTAssertFalse(service.isManuallyPaused(id))

        service.removeTorrent(id, deleteFiles: false)
    }

    // MARK: - Batch deletion (real session)

    /// Batch removal of all torrents produces one coherent end state: no
    /// rows left, no duplicate identities, no error surfaced, no stale
    /// manual-pause records, no deletion placeholders for keep-files.
    @MainActor
    func testBatchRemovalProducesOneCoherentState() {
        let service = makeIsolatedService()
        defer { service.stopSession() }

        service.startSession()
        for name in ["ts-batch-a", "ts-batch-b", "ts-batch-c"] {
            if case .failure(let error) = service.addTorrentFile(data: Self.makeMinimalTorrentData(name: name)) {
                XCTFail("add failed: \(error.localizedDescription)")
            }
        }

        XCTAssertTrue(poll { service.torrents.count == 3 }, "three torrents must appear")
        let ids = service.torrents.map(\.id)

        // Pause two of them so removal must also clean the manual-pause set.
        service.pauseTorrents(Array(ids.prefix(2)))
        XCTAssertTrue(poll { ids.prefix(2).allSatisfy { service.isManuallyPaused($0) } })

        service.removeTorrents(ids, deleteFiles: false)

        XCTAssertTrue(
            poll { service.torrents.isEmpty && service.deletingTorrents.isEmpty },
            "all torrents must disappear after the batch removal"
        )
        XCTAssertNil(service.lastErrorMessage, "no invalid-handle error may surface")
        XCTAssertTrue(ids.allSatisfy { !service.isManuallyPaused($0) },
                      "deleted torrents must lose their manual-pause records")
    }

    /// Remove & Delete Files: the deletion placeholder appears synchronously,
    /// the live row vanishes, and the placeholder clears when libtorrent
    /// reports the files deleted.
    @MainActor
    func testDeleteFilesShowsPlaceholderThenClears() {
        let service = makeIsolatedService()
        defer { service.stopSession() }

        service.startSession()
        if case .failure(let error) = service.addTorrentFile(data: Self.makeMinimalTorrentData(name: "ts-delete-files")) {
            XCTFail("add failed: \(error.localizedDescription)")
        }
        XCTAssertTrue(poll { service.torrents.count == 1 })
        let id = service.torrents[0].id

        service.removeTorrents([id], deleteFiles: true)

        // Bookkeeping is applied synchronously on the main thread.
        XCTAssertFalse(service.torrents.contains { $0.id == id }, "live row must vanish immediately")
        XCTAssertTrue(service.deletingTorrents.contains { $0.id == id },
                      "a deletion placeholder must exist while files are deleted")
        XCTAssertNil(service.lastErrorMessage)

        XCTAssertTrue(
            poll { service.deletingTorrents.isEmpty },
            "the placeholder must clear once libtorrent finishes deleting the files"
        )
        XCTAssertTrue(service.torrents.isEmpty)
    }

    // MARK: - Manual pause persistence (real session)

    /// pause → tear session down → restore a brand-new session over the same
    /// persisted state → the torrent comes back paused. This is the exact
    /// "close app, reopen, open Torrent tab" acceptance flow.
    @MainActor
    func testManualPauseSurvivesSessionRestart() {
        let suiteName = "TorrentServiceTests.restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        var settings = TorrentConnectionSettings.defaultValue
        settings.listenPort = Int.random(in: 7000..<8000)

        // ── First process lifetime ─────────────────────────────────────────
        let service1 = TorrentService(defaults: defaults)
        service1.updateConnectionSettings(settings)
        service1.setNotificationsEnabled(false)
        service1.startSession()
        if case .failure(let error) = service1.addTorrentFile(data: Self.makeMinimalTorrentData(name: "ts-restart")) {
            XCTFail("add failed: \(error.localizedDescription)")
            service1.stopSession()
            return
        }
        XCTAssertTrue(poll { service1.torrents.count == 1 })
        let id = service1.torrents[0].id

        service1.pauseTorrent(id)
        XCTAssertTrue(service1.isManuallyPaused(id))
        XCTAssertTrue(poll { service1.torrents.first(where: { $0.id == id })?.isPaused == true })

        // Full teardown — the app "closes".
        service1.stopSession()

        // ── Second process lifetime ────────────────────────────────────────
        let service2 = TorrentService(defaults: defaults)
        service2.updateConnectionSettings(settings)
        service2.setNotificationsEnabled(false)
        service2.startSession()

        XCTAssertTrue(
            poll { service2.torrents.contains { $0.id == id } },
            "the torrent must be restored by the new session"
        )
        XCTAssertTrue(service2.isManuallyPaused(id), "the manual-pause record must survive the restart")
        XCTAssertTrue(
            poll { service2.torrents.first(where: { $0.id == id })?.isPaused == true },
            "a manually paused torrent must remain paused after session restoration"
        )

        // ── Cleanup ────────────────────────────────────────────────────────
        service2.removeTorrent(id, deleteFiles: false)
        XCTAssertTrue(poll { service2.torrents.isEmpty })
        XCTAssertFalse(service2.isManuallyPaused(id), "removal must clear the manual-pause record")
        service2.stopSession()
    }

    /// Deleting a manually paused torrent clears its pause record, so a
    /// re-added torrent with the same info-hash starts unpaused.
    @MainActor
    func testDeleteClearsManualPauseRecord() {
        let service = makeIsolatedService()
        defer { service.stopSession() }

        service.startSession()
        let data = Self.makeMinimalTorrentData(name: "ts-pause-delete")
        if case .failure(let error) = service.addTorrentFile(data: data) {
            XCTFail("add failed: \(error.localizedDescription)")
        }
        XCTAssertTrue(poll { service.torrents.count == 1 })
        let id = service.torrents[0].id

        service.pauseTorrent(id)
        XCTAssertTrue(service.isManuallyPaused(id))

        service.removeTorrent(id, deleteFiles: false)
        XCTAssertFalse(service.isManuallyPaused(id), "deleting must clear the manual-pause record")
        XCTAssertTrue(poll { service.torrents.isEmpty })

        // The removal is confirmed asynchronously by the engine; a re-add is
        // rejected as a duplicate until it commits, so wait for the commit.
        XCTAssertTrue(poll { !service.isRemovalPending(id) }, "removal must commit before re-add")

        // Re-adding the same torrent must NOT inherit the old pause record.
        if case .failure(let error) = service.addTorrentFile(data: data) {
            XCTFail("re-add failed: \(error.localizedDescription)")
        }
        XCTAssertTrue(poll { service.torrents.count == 1 })
        XCTAssertFalse(service.isManuallyPaused(id), "a re-added torrent must start with a clean slate")
    }

    /// Batch pause records every present torrent; batch resume clears them.
    @MainActor
    func testBatchPauseAndResumeUpdateRecords() {
        let service = makeIsolatedService()
        defer { service.stopSession() }

        service.startSession()
        for name in ["ts-bp-a", "ts-bp-b"] {
            if case .failure(let error) = service.addTorrentFile(data: Self.makeMinimalTorrentData(name: name)) {
                XCTFail("add failed: \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(poll { service.torrents.count == 2 })
        let ids = service.torrents.map(\.id)

        service.pauseTorrents(ids)
        XCTAssertTrue(poll { ids.allSatisfy { service.isManuallyPaused($0) } })

        service.resumeTorrents(ids)
        XCTAssertTrue(ids.allSatisfy { !service.isManuallyPaused($0) })
    }
}
