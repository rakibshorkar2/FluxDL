import SwiftUI

public protocol ThemeServiceProtocol: AnyObject {
    var currentThemeMode: AppThemeMode { get set }
    var colorScheme: ColorScheme? { get }
}

@MainActor
public final class ThemeService: ObservableObject, ThemeServiceProtocol {
    @Published public var currentThemeMode: AppThemeMode {
        didSet {
            UserDefaults.standard.set(currentThemeMode.rawValue, forKey: "fluxdl_theme_preference")
        }
    }
    
    public var colorScheme: ColorScheme? {
        switch currentThemeMode {
        case .system:
            return nil
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }
    
    public init() {
        if let stored = UserDefaults.standard.string(forKey: "fluxdl_theme_preference"),
           let mode = AppThemeMode(rawValue: stored) {
            self.currentThemeMode = mode
        } else {
            self.currentThemeMode = .system
        }
    }
}
