import Foundation
import Combine

/// State presented by the About card's update-check alerts.
public struct UpdateAlert: Identifiable, Equatable {
    public enum Kind: Equatable {
        case upToDate
        case updateAvailable(GitHubRelease)
        case unableToDetermine
        case networkError
        case rateLimited
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var id: String {
        switch kind {
        case .updateAvailable(let release):
            return "update.available.\(release.tagName)"
        case .upToDate:
            return "update.upToDate"
        case .unableToDetermine:
            return "update.unableToDetermine"
        case .networkError:
            return "update.networkError"
        case .rateLimited:
            return "update.rateLimited"
        }
    }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public private(set) var selectedTheme: AppThemeMode
    @Published public private(set) var isCheckingUpdates: Bool = false
    @Published public private(set) var updateAlert: UpdateAlert?
    
    public let settingsService: SettingsServiceProtocol
    private let themeService: ThemeServiceProtocol
    private let hapticService: HapticServiceProtocol
    private let updateChecker: UpdateCheckerProtocol
    private var updateCheckTask: Task<Void, Never>?
    
    public init(
        settingsService: SettingsServiceProtocol = ServiceContainer.shared.settingsService,
        themeService: ThemeServiceProtocol = ServiceContainer.shared.themeService,
        hapticService: HapticServiceProtocol = ServiceContainer.shared.hapticService,
        updateChecker: UpdateCheckerProtocol = UpdateChecker()
    ) {
        self.settingsService = settingsService
        self.themeService = themeService
        self.hapticService = hapticService
        self.updateChecker = updateChecker
        self.selectedTheme = themeService.currentThemeMode
    }
    
    deinit {
        updateCheckTask?.cancel()
    }
    
    public func updateTheme(_ mode: AppThemeMode) {
        selectedTheme = mode
        themeService.currentThemeMode = mode
        hapticService.selectionChanged()
    }
    
    public func checkForUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateAlert = nil
        hapticService.impactOccurred(.light)
        
        updateCheckTask = Task { [weak self] in
            await self?.performUpdateCheck()
        }
    }
    
    public func cancelUpdateCheck() {
        updateCheckTask?.cancel()
        updateCheckTask = nil
    }
    
    private func performUpdateCheck() async {
        defer { isCheckingUpdates = false }
        
        do {
            let result = try await updateChecker.checkForUpdates(forceRefresh: true)
            guard !Task.isCancelled else { return }
            
            if result.updateAvailable {
                updateAlert = UpdateAlert(kind: .updateAvailable(result.latestRelease))
                hapticService.notificationOccurred(.success)
            } else {
                updateAlert = UpdateAlert(kind: .upToDate)
                hapticService.notificationOccurred(.success)
            }
        } catch is CancellationError {
            return
        } catch UpdateCheckError.cancelled {
            return
        } catch UpdateCheckError.rateLimited {
            updateAlert = UpdateAlert(kind: .rateLimited)
            hapticService.notificationOccurred(.error)
        } catch UpdateCheckError.invalidRelease, UpdateCheckError.invalidResponse {
            updateAlert = UpdateAlert(kind: .unableToDetermine)
            hapticService.notificationOccurred(.error)
        } catch {
            updateAlert = UpdateAlert(kind: .networkError)
            hapticService.notificationOccurred(.error)
        }
    }
}
