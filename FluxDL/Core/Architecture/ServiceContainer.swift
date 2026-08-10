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
        self.downloadEngine = engine

        powerMon.startMonitoring(engine: engine)
    }
}
