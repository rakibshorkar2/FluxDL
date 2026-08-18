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
    @StateObject private var incomingDocuments = IncomingDocumentHandler.shared
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
                    // Best-effort cleanup of defensive copies left by an
                    // interrupted import in a previous launch.
                    ImportedDocumentReader.cleanupStaleTemporaryCopies()
                }
                // Documents shared into FluxDL (share sheet / Files "Open
                // with" via CFBundleDocumentTypes): .yaml/.yml route to the
                // Proxy YAML review screen, .torrent to TorrentService.
                .onOpenURL { url in
                    incomingDocuments.handle(url: url)
                }
                .sheet(
                    isPresented: $incomingDocuments.isYAMLResultsPresented,
                    onDismiss: { incomingDocuments.clearYAMLImport() }
                ) {
                    if let result = incomingDocuments.pendingYAMLResult {
                        ProxyYAMLImportView(viewModel: incomingDocuments.proxyViewModel, result: result)
                    }
                }
                .alert(
                    "FluxDL",
                    isPresented: $incomingDocuments.isAlertPresented,
                    presenting: incomingDocuments.alertMessage
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { message in
                    Text(message)
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
                        container.downloadEngine.enterForeground()
                    case .background:
                        container.liveActivityManager.handleAppBackgrounding(tasks: container.downloadEngine.tasks)
                        container.torrentService.handleAppBackgrounding()
                        // Segmented (multi-connection) transfers are foreground
                        // networking with no Apple background guarantee — pause
                        // them; they resume through the reliable background
                        // URLSession path or on foreground.
                        container.downloadEngine.enterBackground()
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
