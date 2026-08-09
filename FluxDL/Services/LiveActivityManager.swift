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

public protocol LiveActivityManagerProtocol: AnyObject {
    func startActivity(for task: DownloadTaskModel)
    func updateActivity(for task: DownloadTaskModel)
    func endActivity(for taskId: UUID)
    func endAllActivities()
    func handleAppBackgrounding(tasks: [DownloadTaskModel])
    func handleAppForegrounding()
}

public final class LiveActivityManager: LiveActivityManagerProtocol {
    private var activeActivities: [UUID: Activity<DownloadActivityAttributes>] = [:]
    private var lastUpdateTimes: [UUID: Date] = [:]
    private var lastProgresses: [UUID: Date] = [:]
    
    private let downloadsLiveActivityKey = "fluxdl_live_activity_downloads"
    
    private var isDownloadsLiveActivityEnabled: Bool {
        UserDefaults.standard.object(forKey: downloadsLiveActivityKey) != nil
            ? UserDefaults.standard.bool(forKey: downloadsLiveActivityKey) : true
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
        guard let activity = activeActivities[taskId] else { return }
        Task {
            await activity.end(dismissalPolicy: .immediate)
            self.activeActivities.removeValue(forKey: taskId)
            self.lastUpdateTimes.removeValue(forKey: taskId)
        }
    }
    
    public func endAllActivities() {
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
}
