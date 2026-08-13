import Foundation
import UIKit
import ActivityKit
import Combine

public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var progress: Double
        public var formattedSpeed: String
        public var formattedETA: String
        public var downloadedSize: String
        public var totalSize: String
        public var status: String
    }
    
    public var filename: String
    public var fileExtension: String
}

public struct BrowserActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var urlString: String
        public var progress: Double
        public var tabCount: Int
        public var status: String
    }

    public var isPrivate: Bool
}

/// Value snapshot of the browser's active tab, pushed into the Live Activity
/// by `BrowserTabManager` (which owns the authoritative tab state).
public struct BrowserActivitySnapshot: Sendable {
    public var title: String
    public var urlString: String
    public var progress: Double
    public var tabCount: Int
    public var isPrivate: Bool
    public var status: String

    public init(title: String, urlString: String, progress: Double,
                tabCount: Int, isPrivate: Bool, status: String) {
        self.title = title
        self.urlString = urlString
        self.progress = progress
        self.tabCount = tabCount
        self.isPrivate = isPrivate
        self.status = status
    }
}

public protocol LiveActivityManagerProtocol: AnyObject {
    func startActivity(for task: DownloadTaskModel)
    func updateActivity(for task: DownloadTaskModel)
    func endActivity(for taskId: UUID)
    func endAllActivities()
    func handleAppBackgrounding(tasks: [DownloadTaskModel])
    func handleAppForegrounding()
    func updateBrowserActivity(snapshot: BrowserActivitySnapshot)
    func endBrowserActivity()
    
    // Torrent Live Activity
    func startTorrentActivity(for task: TorrentTaskModel)
    func updateTorrentActivity(for task: TorrentTaskModel)
    func endTorrentActivity(for torrentId: String)
    func endAllTorrentActivities()
    func handleTorrentAppBackgrounding(tasks: [TorrentTaskModel])
}

public final class LiveActivityManager: LiveActivityManagerProtocol {
    private var activeActivities: [UUID: Activity<DownloadActivityAttributes>] = [:]
    private var lastUpdateTimes: [UUID: Date] = [:]
    private var lastProgresses: [UUID: Date] = [:]
    
    private let downloadsLiveActivityKey = "fluxdl_live_activity_downloads"
    
    // Browser activity (single, reflects the active tab)
    private var browserActivity: Activity<BrowserActivityAttributes>?
    private var lastBrowserUpdate: Date = .distantPast
    private let browserLiveActivityKey = "fluxdl_live_activity_browser"
    
    // Torrent activities (keyed by torrent info-hash)
    private var activeTorrentActivities: [String: Activity<TorrentActivityAttributes>] = [:]
    private var lastTorrentUpdateTimes: [String: Date] = [:]
    /// Last status string posted per torrent; used to break the update
    /// throttle when the state meaningfully changes (pause/resume/complete).
    private var lastTorrentPostedStatuses: [String: String] = [:]
    private let torrentLiveActivityKey = "fluxdl_live_activity_torrents"
    /// Throttle for steady-state progress updates. Status changes bypass it.
    private let torrentUpdateThrottle: TimeInterval = 5.0
    
    private var isDownloadsLiveActivityEnabled: Bool {
        UserDefaults.standard.object(forKey: downloadsLiveActivityKey) != nil
            ? UserDefaults.standard.bool(forKey: downloadsLiveActivityKey) : true
    }
    
    private var isBrowserLiveActivityEnabled: Bool {
        UserDefaults.standard.bool(forKey: browserLiveActivityKey)
    }
    
    private var isTorrentLiveActivityEnabled: Bool {
        UserDefaults.standard.object(forKey: torrentLiveActivityKey) != nil
            ? UserDefaults.standard.bool(forKey: torrentLiveActivityKey) : true
    }
    
    public init() {}
    
    public func startActivity(for task: DownloadTaskModel) {
        // Show in Dynamic Island ONLY if task is downloading, app is in background, AND setting is enabled
        guard isDownloadsLiveActivityEnabled,
              task.status == .downloading,
              UIApplication.shared.applicationState == .background,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            endActivity(for: task.id)
            return
        }
        
        endActivity(for: task.id)
        
        let ext = (task.filename as NSString).pathExtension.lowercased()
        let attributes = DownloadActivityAttributes(filename: task.filename, fileExtension: ext)
        let state = DownloadActivityAttributes.ContentState(
            progress: task.progress,
            formattedSpeed: task.formattedSpeed,
            formattedETA: task.formattedETA,
            downloadedSize: task.formattedDownloadedSize,
            totalSize: task.formattedTotalSize,
            status: task.status.rawValue
        )
        
        do {
            let activity = try Activity<DownloadActivityAttributes>.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            activeActivities[task.id] = activity
            lastUpdateTimes[task.id] = Date()
        } catch {
            print("FluxDL LiveActivity: Failed to start activity: \(error.localizedDescription)")
        }
    }
    
    public func updateActivity(for task: DownloadTaskModel) {
        // As requested: If paused, completed, failed, cancelled, app is in foreground, OR toggle disabled -> END immediately!
        guard isDownloadsLiveActivityEnabled,
              task.status == .downloading,
              UIApplication.shared.applicationState == .background else {
            endActivity(for: task.id)
            return
        }
        
        guard let activity = activeActivities[task.id] else {
            startActivity(for: task)
            return
        }
        
        let now = Date()
        let lastTime = lastUpdateTimes[task.id] ?? .distantPast
        
        // Throttled update
        guard now.timeIntervalSince(lastTime) >= 1.0 else { return }
        
        let newState = DownloadActivityAttributes.ContentState(
            progress: task.progress,
            formattedSpeed: task.formattedSpeed,
            formattedETA: task.formattedETA,
            downloadedSize: task.formattedDownloadedSize,
            totalSize: task.formattedTotalSize,
            status: task.status.rawValue
        )
        
        Task {
            await activity.update(using: newState)
            self.lastUpdateTimes[task.id] = now
        }
    }
    
    public func endActivity(for taskId: UUID) {
        // Remove the entry synchronously BEFORE the async end: a pending
        // end-task must never clobber a freshly re-inserted activity
        // (startActivity re-inserts synchronously right after calling this).
        guard let activity = activeActivities.removeValue(forKey: taskId) else { return }
        lastUpdateTimes.removeValue(forKey: taskId)
        Task {
            await activity.end(dismissalPolicy: .immediate)
        }
    }

    // MARK: - Browser Live Activity

    /// Shows the active tab's title/URL/progress in the Dynamic Island and on
    /// the Lock Screen while the app is backgrounded. Mirrors the downloads
    /// behaviour: toggle off or foreground → the activity ends immediately.
    public func updateBrowserActivity(snapshot: BrowserActivitySnapshot) {
        guard isBrowserLiveActivityEnabled,
              UIApplication.shared.applicationState == .background,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            endBrowserActivity()
            return
        }
        // Only http(s) pages are meaningful in the island.
        guard snapshot.urlString.lowercased().hasPrefix("http") else {
            endBrowserActivity()
            return
        }

        if let activity = browserActivity {
            // Throttled update (max 1 Hz).
            let now = Date()
            guard now.timeIntervalSince(lastBrowserUpdate) >= 1.0 else { return }
            let newState = BrowserActivityAttributes.ContentState(
                title: snapshot.title,
                urlString: snapshot.urlString,
                progress: snapshot.progress,
                tabCount: snapshot.tabCount,
                status: snapshot.status
            )
            Task {
                await activity.update(using: newState)
                self.lastBrowserUpdate = now
            }
        } else {
            let attributes = BrowserActivityAttributes(isPrivate: snapshot.isPrivate)
            let state = BrowserActivityAttributes.ContentState(
                title: snapshot.title,
                urlString: snapshot.urlString,
                progress: snapshot.progress,
                tabCount: snapshot.tabCount,
                status: snapshot.status
            )
            do {
                let activity = try Activity<BrowserActivityAttributes>.request(
                    attributes: attributes,
                    contentState: state,
                    pushType: nil
                )
                browserActivity = activity
                lastBrowserUpdate = Date()
            } catch {
                print("FluxDL LiveActivity: Failed to start browser activity: \(error.localizedDescription)")
            }
        }
    }

    public func endBrowserActivity() {
        guard let activity = browserActivity else { return }
        browserActivity = nil
        Task {
            await activity.end(dismissalPolicy: .immediate)
        }
    }
    
    public func endAllActivities() {
        endBrowserActivity()
        endAllTorrentActivities()
        for (id, _) in activeActivities {
            endActivity(for: id)
        }
    }
    
    public func handleAppBackgrounding(tasks: [DownloadTaskModel]) {
        guard isDownloadsLiveActivityEnabled else { return }
        for task in tasks where task.status == .downloading {
            startActivity(for: task)
        }
    }
    
    public func handleAppForegrounding() {
        endAllActivities()
    }

    // MARK: - Torrent Live Activity

    public func startTorrentActivity(for task: TorrentTaskModel) {
        guard isTorrentLiveActivityEnabled,
              task.isActive,
              UIApplication.shared.applicationState == .background,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            endTorrentActivity(for: task.id)
            return
        }
        
        endTorrentActivity(for: task.id)
        
        let attributes = TorrentActivityAttributes(infoHash: task.id)
        let state = makeTorrentContentState(for: task)
        
        do {
            let activity = try Activity<TorrentActivityAttributes>.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            activeTorrentActivities[task.id] = activity
            lastTorrentUpdateTimes[task.id] = Date()
            lastTorrentPostedStatuses[task.id] = state.status
        } catch {
            print("FluxDL LiveActivity: Failed to start torrent activity: \(error.localizedDescription)")
        }
    }
    
    public func updateTorrentActivity(for task: TorrentTaskModel) {
        guard isTorrentLiveActivityEnabled,
              UIApplication.shared.applicationState == .background else {
            endTorrentActivity(for: task.id)
            return
        }
        
        // Completed → briefly show the completed state, then end.
        if task.isFinished || task.state == .finished {
            if let activity = activeTorrentActivities.removeValue(forKey: task.id) {
                lastTorrentUpdateTimes.removeValue(forKey: task.id)
                lastTorrentPostedStatuses.removeValue(forKey: task.id)
                let finalState = makeTorrentContentState(for: task)
                Task {
                    await activity.update(using: finalState)
                    // Briefly show completed state then end
                    await activity.end(dismissalPolicy: .after(Date().addingTimeInterval(4.0)))
                }
            }
            return
        }
        
        // Storage error → show the error state, then end.
        if task.state == .storageError {
            if let activity = activeTorrentActivities.removeValue(forKey: task.id) {
                lastTorrentUpdateTimes.removeValue(forKey: task.id)
                lastTorrentPostedStatuses.removeValue(forKey: task.id)
                let errorState = makeTorrentContentState(for: task)
                Task {
                    await activity.update(using: errorState)
                    await activity.end(dismissalPolicy: .after(Date().addingTimeInterval(6.0)))
                }
            }
            return
        }
        
        // Paused → reflect the paused state on the existing island instead of
        // ending it, so the user can see why progress stopped. A paused
        // torrent never creates a new activity.
        if task.isPaused {
            guard let activity = activeTorrentActivities[task.id] else { return }
            throttleOrUpdate(activity, task: task)
            return
        }
        
        guard task.isActive else {
            endTorrentActivity(for: task.id)
            return
        }
        
        guard let activity = activeTorrentActivities[task.id] else {
            startTorrentActivity(for: task)
            return
        }
        
        throttleOrUpdate(activity, task: task)
    }
    
    /// Applies the throttling policy for one torrent activity: a status
    /// change is posted immediately, steady-state progress is posted at most
    /// once per `torrentUpdateThrottle`.
    private func throttleOrUpdate(_ activity: Activity<TorrentActivityAttributes>, task: TorrentTaskModel) {
        let newState = makeTorrentContentState(for: task)
        let now = Date()
        let statusChanged = lastTorrentPostedStatuses[task.id] != newState.status
        let lastTime = lastTorrentUpdateTimes[task.id] ?? .distantPast
        guard statusChanged || now.timeIntervalSince(lastTime) >= torrentUpdateThrottle else { return }
        
        Task {
            await activity.update(using: newState)
            self.lastTorrentUpdateTimes[task.id] = now
            self.lastTorrentPostedStatuses[task.id] = newState.status
        }
    }
    
    public func endTorrentActivity(for torrentId: String) {
        // Synchronous removal (same reasoning as endActivity): the deferred
        // end must never delete a freshly re-inserted torrent activity.
        guard let activity = activeTorrentActivities.removeValue(forKey: torrentId) else { return }
        lastTorrentUpdateTimes.removeValue(forKey: torrentId)
        lastTorrentPostedStatuses.removeValue(forKey: torrentId)
        Task {
            await activity.end(dismissalPolicy: .immediate)
        }
    }
    
    public func endAllTorrentActivities() {
        for (id, _) in activeTorrentActivities {
            endTorrentActivity(for: id)
        }
    }
    
    public func handleTorrentAppBackgrounding(tasks: [TorrentTaskModel]) {
        guard isTorrentLiveActivityEnabled else { return }
        for task in tasks where task.isActive {
            startTorrentActivity(for: task)
        }
    }

    private func makeTorrentContentState(for task: TorrentTaskModel) -> TorrentActivityAttributes.ContentState {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let dlFormatted = fmt.string(fromByteCount: task.totalDone)
        let totalFormatted = fmt.string(fromByteCount: task.total)
        let speedDlFormatted = task.downloadRate > 0 ? "\(fmt.string(fromByteCount: task.downloadRate))/s" : "0 B/s"
        let speedUlFormatted = task.uploadRate > 0 ? "\(fmt.string(fromByteCount: task.uploadRate))/s" : "0 B/s"
        
        return TorrentActivityAttributes.ContentState(
            torrentName: task.name,
            progress: task.clampedProgress,
            downloadedSize: dlFormatted,
            totalSize: totalFormatted,
            downloadSpeed: speedDlFormatted,
            uploadSpeed: speedUlFormatted,
            status: task.statusTitle
        )
    }
}
