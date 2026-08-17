import SwiftUI
import UIKit

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            (ServiceContainer.shared.downloadEngine as? DownloadEngine)?.backgroundCompletionHandler = completionHandler
        }
    }
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }
}

// MARK: - App Entry Point

@main
struct FluxDLApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var container = ServiceContainer.shared
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(container)
                .task {
                    await container.notificationService.requestAuthorization()
                    await container.restorationService.restoreActiveTasks(
                        engine: container.downloadEngine as! DownloadEngine
                    )
                }
                .onChange(of: scenePhase) { newPhase in
                    let hasDownloadingTasks = container.downloadEngine.tasks.contains { $0.status == .downloading }
                    let hasActiveTorrents = container.torrentService.torrents.contains { $0.isActive && !$0.isFinished }
                    
                    switch newPhase {
                    case .active:
                        // App in foreground — never run silent audio or GPS keep-alive here.
                        // iOS keeps foreground processes alive natively; keep-alive wastes CPU and heats the device.
                        container.backgroundKeepAliveService.stopAllKeepAlive()
                        container.clipboardService.checkClipboardOnAppActive()
                        container.liveActivityManager.handleAppForegrounding()
                        container.torrentService.handleAppForegrounding()
                    case .background:
                        container.liveActivityManager.handleAppBackgrounding(tasks: container.downloadEngine.tasks)
                        container.torrentService.handleAppBackgrounding()
                        // Aggregated initial state on background transition;
                        // each subsystem then owns its own slot thereafter.
                        container.backgroundKeepAliveService.updateDownloadsKeepAlive(hasDownloadingTasks)
                        container.backgroundKeepAliveService.updateBrowserKeepAlive(!BrowserTabManager.shared.tabs.isEmpty)
                        container.backgroundKeepAliveService.updateTorrentsKeepAlive(hasActiveTorrents)
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
