import SwiftUI

// MARK: - Speed Limit Presets

public enum TorrentSpeedPreset: Int, CaseIterable, Identifiable {
    case unlimited = -1
    case none = 0
    case kb50 = 51_200
    case kb100 = 102_400
    case kb250 = 256_000
    case kb500 = 512_000
    case mb1 = 1_048_576
    case mb2 = 2_097_152
    case mb5 = 5_242_880
    case mb10 = 10_485_760

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .unlimited: return "Unlimited"
        case .none: return "No Transfers"
        case .kb50: return "50 KB/s"
        case .kb100: return "100 KB/s"
        case .kb250: return "250 KB/s"
        case .kb500: return "500 KB/s"
        case .mb1: return "1 MB/s"
        case .mb2: return "2 MB/s"
        case .mb5: return "5 MB/s"
        case .mb10: return "10 MB/s"
        }
    }
}

/// Global session settings: speed limits, queueing limits and notifications.
public struct TorrentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject public var viewModel: TorrentViewModel
    @ObservedObject public var service: TorrentService

    public init(viewModel: TorrentViewModel) {
        self.viewModel = viewModel
        self.service = viewModel.service
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Global Speed Limits"), footer: Text("Limits apply to the whole session and are also capped by any per-torrent limit.")) {
                    Picker("Download Limit", selection: Binding(
                        get: { TorrentSpeedPreset(rawValue: Int(service.globalDownloadSpeed)) ?? .unlimited },
                        set: { viewModel.setGlobalDownloadSpeed(Int64($0.rawValue)) }
                    )) {
                        ForEach(TorrentSpeedPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    Picker("Upload Limit", selection: Binding(
                        get: { TorrentSpeedPreset(rawValue: Int(service.globalUploadSpeed)) ?? .unlimited },
                        set: { viewModel.setGlobalUploadSpeed(Int64($0.rawValue)) }
                    )) {
                        ForEach(TorrentSpeedPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                }

                Section(header: Text("Torrent Queue"), footer: Text("Controls how many torrents run at the same time. Extra torrents wait paused in the queue.")) {
                    Stepper(value: Binding(
                        get: { service.maxActiveTorrents },
                        set: { applyQueue(maxActive: $0) }
                    ), in: 1...50) {
                        LabeledContent("Max Active", value: "\(service.maxActiveTorrents)")
                    }

                    Stepper(value: Binding(
                        get: { service.maxDownloadingTorrents },
                        set: { applyQueue(maxDownloading: $0) }
                    ), in: 0...50) {
                        LabeledContent("Max Downloading", value: "\(service.maxDownloadingTorrents)")
                    }

                    Stepper(value: Binding(
                        get: { service.maxUploadingTorrents },
                        set: { applyQueue(maxUploading: $0) }
                    ), in: 0...50) {
                        LabeledContent("Max Uploading (Seeding)", value: "\(service.maxUploadingTorrents)")
                    }
                }

                Section(header: Text("Notifications"), footer: Text("Sends a notification when a torrent finishes downloading.")) {
                    Toggle("Download Complete Notifications", isOn: Binding(
                        get: { service.notificationsEnabled },
                        set: { viewModel.setNotificationsEnabled($0) }
                    ))
                }
            }
            .navigationTitle("Torrent Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func applyQueue(maxActive: Int? = nil, maxDownloading: Int? = nil, maxUploading: Int? = nil) {
        viewModel.setQueueLimits(
            maxActive: maxActive ?? service.maxActiveTorrents,
            maxDownloading: maxDownloading ?? service.maxDownloadingTorrents,
            maxUploading: maxUploading ?? service.maxUploadingTorrents
        )
    }
}
