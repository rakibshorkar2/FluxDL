import Foundation
import SwiftUI

/// Central Dependency Injection container for FluxDL architecture.
@MainActor
public final class ServiceContainer: ObservableObject {
    public static let shared = ServiceContainer()
    
    public let settingsService: SettingsServiceProtocol
    public let hapticService: HapticServiceProtocol
    public let themeService: ThemeServiceProtocol
    public let downloadRepository: DownloadRepositoryProtocol
    public let downloadHistoryManager: DownloadHistoryManager
    public let fileManagementService: FileManagementServiceProtocol
    public let storageManager: StorageManagerProtocol
    public let queueManager: QueueManagerProtocol
    public let notificationService: NotificationServiceProtocol
    public let restorationService: DownloadRestorationServiceProtocol
    public let clipboardService: ClipboardServiceProtocol
    public let powerNetworkMonitor: PowerNetworkMonitorProtocol
    public let liveActivityManager: LiveActivityManagerProtocol
    public let backgroundKeepAliveService: BackgroundKeepAliveServiceProtocol
    public let downloadEngine: DownloadEngineProtocol
    public let torrentService: TorrentService
    /// Owns the torrent subsystem's background lifecycle (keep-alive claim +
    /// Live Activities), isolated from the downloads/browser machinery.
    public let torrentBackgroundManager: TorrentBackgroundManager
    public let proxyService: ProxyProviding
    
    public init(
        settingsService: SettingsServiceProtocol = MainActor.assumeIsolated { SettingsService() },
        hapticService: HapticServiceProtocol = MainActor.assumeIsolated { HapticService() },
        themeService: ThemeServiceProtocol = MainActor.assumeIsolated { ThemeService() },
        downloadRepository: DownloadRepositoryProtocol = DownloadRepository(),
        fileManagementService: FileManagementServiceProtocol = FileManagementService()
    ) {
        self.settingsService = settingsService
        self.hapticService = hapticService
        self.themeService = themeService
        self.downloadRepository = downloadRepository
        self.downloadHistoryManager = DownloadHistoryManager(repository: downloadRepository)
        self.fileManagementService = fileManagementService
        self.storageManager = StorageManager(fileManagementService: fileManagementService)
        self.queueManager = QueueManager()
        
        let notifService = NotificationService()
        self.notificationService = notifService
        self.restorationService = DownloadRestorationService()
        self.clipboardService = ClipboardService()
        self.liveActivityManager = LiveActivityManager()
        self.backgroundKeepAliveService = BackgroundKeepAliveService()
        
let powerMon = PowerNetworkMonitor()
        self.powerNetworkMonitor = powerMon

        let proxy = ProxyService()
        self.proxyService = proxy
        self.torrentService = TorrentService.shared

        // Constructed after torrentService (never inside TorrentService.init)
        // so no static-init recursion occurs. The manager claims the torrents
        // keep-alive slot and drives torrent Live Activities — it never
        // touches the proxy.
        let torrentBackground = TorrentBackgroundManager(
            keepAliveService: backgroundKeepAliveService,
            liveActivityManager: liveActivityManager
        )
        self.torrentBackgroundManager = torrentBackground
        self.torrentService.configureBackgroundLifecycle(torrentBackground)

        let engine = DownloadEngine(
            repository: downloadRepository,
            fileManagerService: fileManagementService,
            hapticService: hapticService,
            notificationService: notifService
        )
        engine.proxyProvider = proxy
        proxy.onProxyStateChange = { [weak engine] in
            engine?.refreshProxyRouting()
        }
        // When the proxy route becomes usable again (enable, recovery after a
        // failed switch), pending downloads blocked by the fail-closed guard
        // are released through the normal scheduler.
        engine.onRoutingStateChange = { [weak engine] in
            guard let engine else { return }
            ServiceContainer.shared.queueManager.scheduleNextTasks(in: engine)
        }
        self.downloadEngine = engine

        downloadHistoryManager.startObserving(engine: engine)

        powerMon.startMonitoring(engine: engine)
    }
}
