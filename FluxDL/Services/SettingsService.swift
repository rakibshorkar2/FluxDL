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
    public let versionString: String = "1.0.0"
    public let buildString: String = "1"
    public let githubURL: URL? = URL(string: "https://github.com/rakibshorkar2/FluxDL")
    public let privacyURL: URL? = URL(string: "https://github.com/rakibshorkar2/FluxDL/blob/main/PRIVACY.md")
    public let termsURL: URL? = URL(string: "https://github.com/rakibshorkar2/FluxDL/blob/main/TERMS.md")
    
    private let themeKey = "fluxdl_app_theme_mode"
    
    public var themeMode: AppThemeMode {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: themeKey),
                  let mode = AppThemeMode(rawValue: rawValue) else {
                return .system
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
        }
    }
    
    public init() {}
    
    public func checkForUpdates() async -> String {
        // Asynchronous check simulation without blocking thread
        try? await Task.sleep(nanoseconds: 500_000_000)
        return "FluxDL v1.0.0 (Build 1) is currently up to date."
    }
}
