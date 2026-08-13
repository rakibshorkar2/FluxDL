import XCTest
@testable import FluxDL

final class TorrentCompletionTrackerTests: XCTestCase {

    private let key = "Torrent.CompletionTrackerTests.key"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testNoteCompletedFiresExactlyOnce() {
        let tracker = TorrentCompletionTracker(storageKey: key)
        tracker.establishBaseline(with: [])

        XCTAssertTrue(tracker.noteCompleted("A"), "first completion must fire")
        XCTAssertFalse(tracker.noteCompleted("A"), "second poll cycle must not re-fire")
        XCTAssertFalse(tracker.noteCompleted("A"))
        XCTAssertTrue(tracker.contains("A"))
    }

    func testBaselineAbsorbsAlreadyCompleteTorrents() {
        let tracker = TorrentCompletionTracker(storageKey: key)
        tracker.establishBaseline(with: ["A", "B"])

        XCTAssertFalse(tracker.noteCompleted("A"), "restored-complete torrents are absorbed silently")
        XCTAssertTrue(tracker.noteCompleted("C"), "torrents completing after launch still fire")
    }

    func testPersistenceSurvivesReinstantiation() {
        let first = TorrentCompletionTracker(storageKey: key)
        first.establishBaseline(with: [])
        _ = first.noteCompleted("A")

        let second = TorrentCompletionTracker(storageKey: key)
        XCTAssertFalse(second.noteCompleted("A"), "persisted hash must not fire twice")
    }

    func testRemoveAllowsFreshNotificationForReaddedTorrent() {
        let tracker = TorrentCompletionTracker(storageKey: key)
        tracker.establishBaseline(with: [])
        XCTAssertTrue(tracker.noteCompleted("A"))

        tracker.remove("A")
        XCTAssertFalse(tracker.contains("A"))
        XCTAssertTrue(tracker.noteCompleted("A"), "re-added torrent with same hash fires again")
    }

    func testBaselineIsEstablishedOnlyOnce() {
        let tracker = TorrentCompletionTracker(storageKey: key)
        tracker.establishBaseline(with: ["A"])
        // A second baseline call must not re-absorb; noteCompleted drives
        // everything from here on.
        tracker.establishBaseline(with: ["B"])
        XCTAssertTrue(tracker.noteCompleted("B"), "baseline already established, B completes normally")
    }
}
