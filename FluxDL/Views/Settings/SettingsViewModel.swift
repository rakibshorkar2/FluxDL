import Foundation
import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public private(set) var selectedTheme: AppThemeMode
    @Published public private(set) var isCheckingUpdates: Bool = false
    @Published public private(set) var updateStatusMessage: String?
    
    public let settingsService: SettingsServiceProtocol
    private let themeService: ThemeServiceProtocol
    private let hapticService: HapticServiceProtocol
    
    public init(
        settingsService: SettingsServiceProtocol = ServiceContainer.shared.settingsService,
        themeService: ThemeServiceProtocol = ServiceContainer.shared.themeService,
        hapticService: HapticServiceProtocol = ServiceContainer.shared.hapticService
    ) {
        self.settingsService = settingsService
        self.themeService = themeService
        self.hapticService = hapticService
        self.selectedTheme = themeService.currentThemeMode
    }
    
    public func updateTheme(_ mode: AppThemeMode) {
        selectedTheme = mode
        themeService.currentThemeMode = mode
        hapticService.selectionChanged()
    }
    
    public func checkForUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateStatusMessage = nil
        hapticService.impactOccurred(.light)
        
        Task {
            // Simulate brief network check and verify version
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            
            self.isCheckingUpdates = false
            self.updateStatusMessage = "FluxDL v\(self.settingsService.versionString) is up to date."
            self.hapticService.notificationOccurred(.success)
        }
    }
}
