import Foundation
import UIKit

/// Owns the torrent subsystem's background lifecycle in isolation.
///
/// iOS does not grant arbitrary background CPU time. The LibTorrent engine
/// runs its own threads inside this process, so the strongest legitimate
/// way to keep it transferring while backgrounded is to hold the process
/// alive: this manager claims the torrents slot of the shared
/// `BackgroundKeepAliveService` (silent audio + location — the same
/// infrastructure the downloads and browser subsystems use, through
/// independent slots so no subsystem can cancel another's claim).
///
/// Lifecycle:
/// 1. a torrent starts transferring → the keep-alive claim is raised
/// 2. the app backgrounds → torrent Live Activities start/update
/// 3. the engine keeps running (process stays alive) and state keeps
///    being persisted on every refresh
/// 4. completion is detected by `TorrentService` → notification fires and
///    the Live Activity shows "Completed" briefly, then ends
/// 5. no active torrents remain → the claim is released and the keep-alive
///    lifecycle ends (nothing is kept alive forever)
///
/// This manager deliberately never touches `ProxyService`,
/// `ProxySessionProvider` or `BrowserProxySession` — torrent traffic uses
/// LibTorrent's own session/network configuration exclusively.
public final class TorrentBackgroundManager {

    private let keepAliveService: BackgroundKeepAliveServiceProtocol
    private let liveActivityManager: LiveActivityManagerProtocol

    public init(
        keepAliveService: BackgroundKeepAliveServiceProtocol,
        liveActivityManager: LiveActivityManagerProtocol
    ) {
        self.keepAliveService = keepAliveService
        self.liveActivityManager = liveActivityManager
    }

    /// Called after every engine refresh with the latest snapshots.
    /// Re-evaluates the keep-alive claim (idempotent, cheap when nothing
    /// changed) and, while backgrounded, drives the torrent Live Activities.
    public func update(
        with torrents: [TorrentTaskModel],
        appState: UIApplication.State = UIApplication.shared.applicationState
    ) {
        let hasActive = torrents.contains { $0.isActive && !$0.isFinished }
        keepAliveService.updateTorrentsKeepAlive(hasActive)

        guard appState == .background else { return }
        for model in torrents {
            liveActivityManager.updateTorrentActivity(for: model)
        }
    }

    /// The app moved to the background: raise the keep-alive claim if any
    /// torrent is active and start Live Activities for active torrents.
    public func handleAppBackgrounding(torrents: [TorrentTaskModel]) {
        let hasActive = torrents.contains { $0.isActive && !$0.isFinished }
        keepAliveService.updateTorrentsKeepAlive(hasActive)
        liveActivityManager.handleTorrentAppBackgrounding(tasks: torrents)
    }

    /// The app returned to the foreground: iOS keeps foreground processes
    /// alive natively, so release the claim and end torrent activities.
    public func handleAppForegrounding() {
        keepAliveService.updateTorrentsKeepAlive(false)
        liveActivityManager.endAllTorrentActivities()
    }

    /// A torrent was removed/cancelled: end its Live Activity.
    public func torrentRemoved(id: String) {
        liveActivityManager.endTorrentActivity(for: id)
    }
}