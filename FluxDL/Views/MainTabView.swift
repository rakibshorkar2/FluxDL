import SwiftUI

public enum AppTab: Int, CaseIterable, Identifiable {
    case downloads = 0
    case browser = 1
    case history = 2
    case settings = 3
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .downloads: return "Downloads"
        case .browser: return "Browser"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }
    
    public var iconName: String {
        switch self {
        case .downloads: return "arrow.down.circle.fill"
        case .browser: return "globe"
        case .history: return "clock.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

public struct MainTabView: View {
    @State private var selectedTab: AppTab = .downloads
    @ObservedObject private var themeService: ThemeService = (ServiceContainer.shared.themeService as? ThemeService) ?? ThemeService()
    @ObservedObject private var clipboardService: ClipboardService = (ServiceContainer.shared.clipboardService as? ClipboardService) ?? ClipboardService()
    
    private let hapticService: HapticServiceProtocol = ServiceContainer.shared.hapticService
    
    public init() {}
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: Binding(
                get: { selectedTab },
                set: { newTab in
                    if newTab != selectedTab {
                        selectedTab = newTab
                        hapticService.selectionChanged()
                    }
                }
            )) {
                DownloadsView()
                    .tabItem {
                        Label(AppTab.downloads.title, systemImage: AppTab.downloads.iconName)
                    }
                    .tag(AppTab.downloads)
                
                BrowserView()
                    .tabItem {
                        Label(AppTab.browser.title, systemImage: AppTab.browser.iconName)
                    }
                    .tag(AppTab.browser)
                
                HistoryView()
                    .tabItem {
                        Label(AppTab.history.title, systemImage: AppTab.history.iconName)
                    }
                    .tag(AppTab.history)
                
                SettingsView()
                    .tabItem {
                        Label(AppTab.settings.title, systemImage: AppTab.settings.iconName)
                    }
                    .tag(AppTab.settings)
            }
            
            // Smart Clipboard Overlay Banner (Phase 8)
            if let detectedURL = clipboardService.detectedURL {
                VStack {
                    GlassCard(padding: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Link Copied to Clipboard")
                                    .font(.caption.bold())
                                Text(detectedURL.absoluteString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                _ = ServiceContainer.shared.downloadEngine.startDownload(url: detectedURL, filename: nil)
                                clipboardService.dismissDetectedURL()
                                selectedTab = .downloads
                            }) {
                                Text("Download")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.accentColor)
                            
                            Button(action: {
                                clipboardService.dismissDetectedURL()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(), value: clipboardService.detectedURL)
            }
        }
        .preferredColorScheme(themeService.colorScheme)
    }
}
