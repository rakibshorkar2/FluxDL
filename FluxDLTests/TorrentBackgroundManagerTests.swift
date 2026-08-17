import XCTest
import UIKit
@testable import FluxDL

private final class MockKeepAliveService: BackgroundKeepAliveServiceProtocol {
    var torrentsClaim: Bool?
    var claimedCount = 0

    func updateDownloadsKeepAlive(_ active: Bool) {}
    func updateBrowserKeepAlive(_ active: Bool) {}
    func updateTorrentsKeepAlive(_ active: Bool) {
        torrentsClaim = active
        claimedCount += 1
    }
    func stopAllKeepAlive() {}
}

private final class MockLiveActivityManager: LiveActivityManagerProtocol {
    var updatedTorrents: [String] = []
    var backgroundedTorrents: [String] = []
    var endedAllCount = 0
    var endedIDs: [String] = []

    func startActivity(for task: DownloadTaskModel) {}
    func updateActivity(for task: DownloadTaskModel) {}
    func endActivity(for taskId: UUID) {}
    func handleAppBackgrounding(tasks: [DownloadTaskModel]) {}
    func handleAppForegrounding() {}

    func startTorrentActivity(for task: TorrentTaskModel) {
        backgroundedTorrents.append(task.id)
    }
    func updateTorrentActivity(for task: TorrentTaskModel) {
        updatedTorrents.append(task.id)
    }
    func endTorrentActivity(for torrentId: String) {
        endedIDs.append(torrentId)
    }
    func endAllTorrentActivities() {
        endedAllCount += 1
    }
    func handleTorrentAppBackgrounding(tasks: [TorrentTaskModel]) {
        backgroundedTorrents = tasks.map(\.id)
    }
}

final class TorrentBackgroundManagerTests: XCTestCase {

    private var keepAlive: MockKeepAliveService!
    private var liveActivity: MockLiveActivityManager!
    private var manager: TorrentBackgroundManager!

    override func setUp() {
        super.setUp()
        keepAlive = MockKeepAliveService()
        liveActivity = MockLiveActivityManager()
        manager = TorrentBackgroundManager(
            keepAliveService: keepAlive,
            liveActivityManager: liveActivity
        )
    }

    /// A backgrounded refresh with at least one active torrent raises the
    /// keep-alive claim and drives the Live Activity.
    func testUpdateInBackgroundRaisesClaimAndUpdatesActivity() {
        let active = TorrentTaskModel.makeStub(id: "A", name: "Active", stateName: "downloading")
        manager.update(with: [active], appState: .background)

        XCTAssertEqual(keepAlive.torrentsClaim, true)
        XCTAssertEqual(liveActivity.updatedTorrents, ["A"])
    }

    /// No active torrents → the claim is released and no activity is started.
    func testUpdateWithNoActiveTorrentsReleasesClaim() {
        let paused = TorrentTaskModel.makeStub(id: "P", name: "Paused", stateName: "paused", isPaused: true)
        manager.update(with: [paused], appState: .background)

        XCTAssertEqual(keepAlive.torrentsClaim, false)
        XCTAssertTrue(liveActivity.updatedTorrents.isEmpty)
    }

    /// Foreground refreshes must not touch Live Activities (they are ended by
    /// handleAppForegrounding) but the claim evaluation is still idempotent.
    func testUpdateInForegroundDoesNotDriveActivities() {
        let active = TorrentTaskModel.makeStub(id: "A", name: "Active")
        manager.update(with: [active], appState: .active)

        XCTAssertTrue(liveActivity.updatedTorrents.isEmpty)
        XCTAssertNil(keepAlive.torrentsClaim)
    }

    func testBackgroundingStartsActivitiesAndClaims() {
        let active = TorrentTaskModel.makeStub(id: "A", name: "Active")
        let seeding = TorrentTaskModel.makeStub(id: "S", name: "Seeding", stateName: "seeding", isSeed: true, isFinished: true)
        manager.handleAppBackgrounding(torrents: [active, seeding])

        XCTAssertEqual(keepAlive.torrentsClaim, true)
        XCTAssertEqual(liveActivity.backgroundedTorrents, ["A", "S"])
    }

    func testForegroundingReleasesClaimAndEndsActivities() {
        manager.handleAppForegrounding()

        XCTAssertEqual(keepAlive.torrentsClaim, false)
        XCTAssertEqual(liveActivity.endedAllCount, 1)
    }

    func testTorrentRemovalEndsItsActivityOnly() {
        manager.torrentRemoved(id: "A")
        XCTAssertEqual(liveActivity.endedIDs, ["A"])
    }
}
