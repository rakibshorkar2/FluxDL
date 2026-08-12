import SwiftUI

// MARK: - Settings-specific opaque card
// GlassCard uses .ultraThinMaterial which requires live GPU backdrop sampling every scroll frame.
// SettingsCard uses a plain opaque fill — dramatically reduces GPU load and eliminates scroll stutter.
private struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.06),
                                lineWidth: 0.8
                            )
                    )
            }
    }
}

// MARK: - General & Haptic (TOP CARD)
private struct GeneralSettingsCard: View {
    @ObservedObject var viewModel: SettingsViewModel
    @AppStorage("fluxdl_haptics_enabled") private var hapticsEnabled: Bool = true

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color.blue)
                    Text("General")
                        .font(.headline)
                }

                Toggle(isOn: $hapticsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Haptic Feedback")
                        Text("Tactile response for interactions & alerts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.blue)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme Mode")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("Theme Mode", selection: Binding(
                        get: { viewModel.selectedTheme },
                        set: { viewModel.updateTheme($0) }
                    )) {
                        ForEach(AppThemeMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}

// MARK: - Downloads Advanced Settings Card
private struct DownloadsSettingsCard: View {
    @AppStorage("fluxdl_max_concurrent_downloads") private var maxConcurrent: Int = 3
    @AppStorage("fluxdl_auto_retry_enabled") private var autoRetry: Bool = true
    @AppStorage("fluxdl_max_retry_count") private var maxRetryCount: Int = 3
    @AppStorage("fluxdl_retry_delay_seconds") private var retryDelaySeconds: Int = 5
    @AppStorage("fluxdl_show_notifications") private var showNotifications: Bool = true
    @AppStorage("fluxdl_smart_routing") private var smartRouting: Bool = true
    @AppStorage("fluxdl_screen_awake_minutes") private var screenAwakeMinutes: Int = 0
    @AppStorage("fluxdl_screen_awake_custom") private var screenAwakeCustom: Int = 10
    @AppStorage("fluxdl_bg_keepalive_downloads") private var bgKeepAliveDownloads: Bool = true
    @AppStorage("fluxdl_live_activity_downloads") private var liveActivityDownloads: Bool = true

    // Presets (shown only when keep-awake is enabled)
    private let durationPresets: [(label: String, value: Int)] = [
        ("While Downloading", -1),
        ("5 min", 5),
        ("15 min", 15),
        ("30 min", 30),
        ("60 min", 60),
        ("Custom", -99),
    ]

    private var isScreenAwakeOn: Bool { screenAwakeMinutes != 0 }

    private var currentDurationLabel: String {
        durationPresets.first(where: { $0.value == screenAwakeMinutes })?.label ?? "Custom"
    }

    private var isCustomMode: Bool {
        screenAwakeMinutes > 0 && !durationPresets.contains(where: { $0.value == screenAwakeMinutes })
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Downloads Controls")
                        .font(.headline)
                }

                // Concurrent Downloads
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Concurrent Downloads")
                        Spacer()
                        Text("\(maxConcurrent)")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                    Stepper("Max Parallel", value: $maxConcurrent, in: 1...10)
                }

                Divider()

                // Auto-Retry
                Toggle(isOn: $autoRetry) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Retry Failed Downloads")
                        Text("Automatically retry when connection fails")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.accentColor)

                if autoRetry {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max Retry Count")
                            Spacer()
                            Text("\(maxRetryCount) attempts")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        Stepper("Retry Count", value: $maxRetryCount, in: 1...10)

                        HStack {
                            Text("Retry Delay")
                            Spacer()
                            Text("\(retryDelaySeconds)s")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        Stepper("Retry Delay", value: $retryDelaySeconds, in: 1...60, step: 2)
                    }
                    .padding(.leading, 12)
                }

                Divider()

                // Notifications
                Toggle(isOn: $showNotifications) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download Notifications")
                        Text("Show alert when a file finishes or fails")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.accentColor)

                Divider()

                // Smart Routing
                Toggle(isOn: $smartRouting) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart Folder Routing")
                        Text("Auto-sort into Videos, Music, Documents, Archives, Apps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.green)

                Divider()

                // ── Keep Screen Awake ───────────────────────────────────────
                // Compact toggle row, expands below when enabled (like all other options).
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Screen Awake")
                        Text(isScreenAwakeOn
                             ? "Duration: \(currentDurationLabel)"
                             : "Prevent display sleep while active")
                            .font(.caption)
                            .foregroundStyle(isScreenAwakeOn ? Color.orange : Color.secondary)
                            .animation(.easeInOut(duration: 0.15), value: isScreenAwakeOn)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isScreenAwakeOn },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                screenAwakeMinutes = newValue ? -1 : 0
                            }
                        }
                    ))
                    .tint(Color.orange)
                    .labelsHidden()
                }

                // Expanded duration options — shown only when Keep Screen Awake is ON
                if isScreenAwakeOn {
                    VStack(alignment: .leading, spacing: 10) {
                        // Duration preset chips
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                            spacing: 8
                        ) {
                            ForEach(durationPresets, id: \.value) { preset in
                                let isSelected: Bool = {
                                    if preset.value == -99 { return isCustomMode }
                                    return screenAwakeMinutes == preset.value
                                }()

                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if preset.value == -99 {
                                            screenAwakeMinutes = screenAwakeCustom > 0 ? screenAwakeCustom : 10
                                        } else {
                                            screenAwakeMinutes = preset.value
                                        }
                                    }
                                } label: {
                                    Text(preset.label)
                                        .font(.caption.bold())
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                        .padding(.vertical, 7)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            isSelected ? Color.orange : Color.primary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Custom duration stepper — shown only when custom chip is selected
                        if isCustomMode {
                            HStack {
                                Text("Custom duration")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Stepper(
                                    "\(screenAwakeCustom) min",
                                    value: Binding(
                                        get: { screenAwakeCustom },
                                        set: { v in
                                            screenAwakeCustom = v
                                            screenAwakeMinutes = v
                                        }
                                    ),
                                    in: 1...60
                                )
                                .fixedSize()
                            }
                            .padding(.top, 2)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()

                // Background Keep-Alive
                Toggle(isOn: $bgKeepAliveDownloads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background Keep-Alive")
                        Text("Silent audio & location to keep app active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.indigo)

                Divider()

                // Live Activity
                Toggle(isOn: $liveActivityDownloads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Activity & Dynamic Island")
                        Text("Show progress on Lock Screen and Dynamic Island")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.purple)
            }
        }
    }
}

// MARK: - Browser Tab Settings Card
private struct BrowserSettingsCard: View {
    @AppStorage("fluxdl_bg_keepalive_browser") private var bgKeepAliveBrowser: Bool = false
    @AppStorage("fluxdl_live_activity_browser") private var liveActivityBrowser: Bool = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(Color.purple)
                    Text("Browser Tab Controls")
                        .font(.headline)
                }

                Toggle(isOn: $bgKeepAliveBrowser) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browser Background Keep-Alive")
                        Text("Keep browser tab alive in background")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.purple)

                Divider()

                Toggle(isOn: $liveActivityBrowser) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browser Live Activity")
                        Text("Display browser status in Dynamic Island")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.purple)
            }
        }
    }
}

// MARK: - Torrent Tab Settings Card
private struct TorrentSettingsCard: View {
    @AppStorage("fluxdl_bg_keepalive_torrents") private var bgKeepAliveTorrents: Bool = true
    @AppStorage("fluxdl_live_activity_torrents") private var liveActivityTorrents: Bool = true

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "magnet")
                        .foregroundStyle(Color.red)
                    Text("Torrent Controls")
                        .font(.headline)
                }

                Toggle(isOn: $bgKeepAliveTorrents) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Torrent Background Keep-Alive")
                        Text("Keep torrent downloading active in background")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.red)

                Divider()

                Toggle(isOn: $liveActivityTorrents) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Torrent Live Activity")
                        Text("Display torrent progress in Dynamic Island")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.red)
            }
        }
    }
}

// MARK: - Power & Battery Card
private struct PowerNetworkCard: View {
    @AppStorage("fluxdl_wifi_only") private var isWiFiOnly: Bool = false
    @AppStorage("fluxdl_low_battery_pause") private var lowBatteryPause: Bool = true
    @AppStorage("fluxdl_battery_threshold") private var batteryThresholdPercent: Int = 20
    @AppStorage("fluxdl_bandwidth_limit") private var bandwidthLimitKBps: Int = 0

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Color.orange)
                    Text("Power & Network")
                        .font(.headline)
                }

                Toggle(isOn: $isWiFiOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi Only Downloads")
                        Text("Pause downloads when on cellular data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.accentColor)

                Divider()

                Toggle(isOn: $lowBatteryPause) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Low Battery Auto-Pause")
                        Text("Pause when battery falls below threshold")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.orange)

                if lowBatteryPause {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Pause Threshold")
                            Spacer()
                            Text("\(batteryThresholdPercent)%")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.orange)
                        }
                        Stepper("Threshold", value: $batteryThresholdPercent, in: 5...50, step: 5)
                    }
                    .padding(.leading, 12)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bandwidth Limiter")
                        Spacer()
                        Text(bandwidthLimitKBps == 0 ? "Unlimited" : "\(bandwidthLimitKBps) KB/s")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                    Stepper("Limit Speed", value: $bandwidthLimitKBps, in: 0...10240, step: 256)
                }
            }
        }
    }
}

// MARK: - About Card
private struct AboutCard: View {
    @ObservedObject var viewModel: SettingsViewModel
    let openURL: OpenURLAction

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.primaryGradient)
                            .frame(width: 54, height: 54)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.settingsService.appName)
                            .font(.title2.bold())
                        HStack(spacing: 4) {
                            Text("Developer:").foregroundStyle(.secondary)
                            Text(viewModel.settingsService.developerName)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                        .font(.subheadline)
                    }
                    Spacer()
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version").font(.caption).foregroundStyle(.secondary)
                        Text(viewModel.settingsService.versionString).font(.body.weight(.medium))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Build").font(.caption).foregroundStyle(.secondary)
                        Text(viewModel.settingsService.buildString).font(.body.weight(.medium))
                    }
                }

                Divider()

                VStack(spacing: 12) {
                    SettingsLinkRow(label: "GitHub Repository", icon: "link", detail: "rakibshorkar2/FluxDL") {
                        if let url = viewModel.settingsService.githubURL { openURL(url) }
                    }
                    SettingsLinkRow(label: "Licenses", icon: "doc.text", detail: "MIT") {}
                    SettingsLinkRow(label: "Privacy Policy", icon: "hand.raised.fill") {
                        if let url = viewModel.settingsService.privacyURL { openURL(url) }
                    }
                    SettingsLinkRow(label: "Terms of Service", icon: "checkmark.shield.fill") {
                        if let url = viewModel.settingsService.termsURL { openURL(url) }
                    }
                }

                Divider()

                Button(action: { viewModel.checkForUpdates() }) {
                    HStack {
                        Spacer()
                        if viewModel.isCheckingUpdates {
                            ProgressView().scaleEffect(0.8).padding(.trailing, 4)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(viewModel.isCheckingUpdates ? "Checking..." : "Check for Updates")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall))
                    .foregroundStyle(Color.blue)
                }

                if let msg = viewModel.updateStatusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

// MARK: - Reusable Link Row
private struct SettingsLinkRow: View {
    let label: String
    let icon: String
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: icon).foregroundStyle(.primary)
                Spacer()
                if let d = detail {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Main SettingsView

public struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        NavigationStack {
            // Plain ScrollView — no material blur during scroll = smooth 120Hz
            ScrollView {
                VStack(spacing: 16) {
                    // 1. General (top)
                    GeneralSettingsCard(viewModel: viewModel)

                    // 2. Downloads Controls
                    DownloadsSettingsCard()

                    // 3. Browser Controls
                    BrowserSettingsCard()

                    // 4. Torrent Controls
                    TorrentSettingsCard()

                    // 5. Power & Network
                    PowerNetworkCard()

                    // 6. About (bottom)
                    AboutCard(viewModel: viewModel, openURL: openURL)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            // Opaque solid background — no extra compositing layer
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }
}
