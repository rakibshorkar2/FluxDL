import SwiftUI

public enum AppTab: Int, CaseIterable, Identifiable {
    case downloads = 0
    case browser = 1
    case proxy = 2
    case settings = 3
    case torrent = 4
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .downloads: return "Downloads"
        case .browser: return "Browser"
        case .proxy: return "Proxy"
        case .settings: return "Settings"
        case .torrent: return "Torrent"
        }
    }
    
    public var iconName: String {
        switch self {
        case .downloads: return "arrow.down.circle.fill"
        case .browser: return "globe"
        case .proxy: return "arrow.left.arrow.right"
        case .settings: return "gearshape.fill"
        case .torrent: return "network"
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
                
                BrowserView(onOpenDownloads: {
                    selectedTab = .downloads
                    hapticService.selectionChanged()
                })
                    .tabItem {
                        Label(AppTab.browser.title, systemImage: AppTab.browser.iconName)
                    }
                    .tag(AppTab.browser)
                
                ProxyView()
                    .tabItem {
                        Label(AppTab.proxy.title, systemImage: AppTab.proxy.iconName)
                    }
                    .tag(AppTab.proxy)
                
                SettingsView()
                    .tabItem {
                        Label(AppTab.settings.title, systemImage: AppTab.settings.iconName)
                    }
                    .tag(AppTab.settings)
                
                TorrentView()
                    .tabItem {
                        Label(AppTab.torrent.title, systemImage: AppTab.torrent.iconName)
                    }
                    .tag(AppTab.torrent)
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
