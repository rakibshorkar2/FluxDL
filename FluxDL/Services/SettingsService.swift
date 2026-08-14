import Foundation

public enum AppThemeMode: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"
    
    public var id: String { rawValue }
}

public protocol SettingsServiceProtocol: AnyObject {
    var appName: String { get }
    var developerName: String { get }
    var versionString: String { get }
    var buildString: String { get }
    var githubURL: URL? { get }
    var privacyURL: URL? { get }
    var termsURL: URL? { get }
    var themeMode: AppThemeMode { get set }
    func checkForUpdates() async -> String
}

@MainActor
public final class SettingsService: SettingsServiceProtocol {
    public let appName: String = "FluxDL"
    public let developerName: String = "RAKIB"
    public let versionString: String
    public let buildString: String
    public let githubURL: URL? = URL(string: "https://github.com/rakibshorkar2/FluxDL")
    public let privacyURL: URL? = URL(string: "https://github.com/rakibshorkar2/FluxDL/blob/main/PRIVACY.md")
    public let termsURL: URL? = URL(string: "https://github.com/rakibshorkar2/FluxDL/blob/main/TERMS.md")
    
    private let versionService: AppVersionServiceProtocol
    private let themeKey = "fluxdl_theme_preference"
    /// Legacy key written by older builds — read as a fallback only.
    private let legacyThemeKey = "fluxdl_app_theme_mode"

    public var themeMode: AppThemeMode {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: themeKey),
               let mode = AppThemeMode(rawValue: rawValue) {
                return mode
            }
            // Migrate the old key so previously chosen themes survive.
            if let rawValue = UserDefaults.standard.string(forKey: legacyThemeKey),
               let mode = AppThemeMode(rawValue: rawValue) {
                UserDefaults.standard.set(rawValue, forKey: themeKey)
                return mode
            }
            return .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
        }
    }
    
    public init(versionService: AppVersionServiceProtocol = AppVersionService()) {
        self.versionService = versionService
        self.versionString = versionService.versionString
        self.buildString = versionService.buildString
    }
    
    public func checkForUpdates() async -> String {
        // Real GitHub Releases check through the shared update checker.
        let checker = UpdateChecker()
        do {
            let result = try await checker.checkForUpdates(forceRefresh: true)
            if result.updateAvailable {
                return "FluxDL \(result.latestRelease.version) is available."
            }
            return "FluxDL v\(versionString) is up to date."
        } catch UpdateCheckError.rateLimited {
            return "GitHub API rate limit reached. Please try again later."
        } catch UpdateCheckError.cancelled {
            return "Update check cancelled."
        } catch {
            return "Couldn't check for updates. Please check your Internet connection and try again."
        }
    }
}
