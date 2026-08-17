import WidgetKit
import SwiftUI
import ActivityKit

/// Live Activity for torrent downloads: Dynamic Island (compact/expanded),
/// Lock Screen and Banner. Renders `TorrentActivityAttributes` (defined in
/// the shared app source file compiled into both targets) so the widget side
/// matches the app side's ActivityKit registration.
struct TorrentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TorrentActivityAttributes.self) { context in
            LockScreenTorrentView(activityState: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandProgressView(activityState: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.status)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(context.state.downloadSpeed)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.torrentName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .progressViewStyle(.linear)
                        .tint(.green)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.to.line")
                    .foregroundColor(.green)
            } compactTrailing: {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .tint(.green)
            } minimal: {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .tint(.green)
            }
        }
    }
}

/// Shared presentation helpers (used by both the lock screen and the island).
struct IslandProgressView: View {
    let activityState: TorrentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(activityState.torrentName)
                .font(.headline)
                .lineLimit(1)
            Text(activityState.status)
                .font(.caption2)
                .foregroundColor(.secondary)
            ProgressView(value: activityState.progress)
                .progressViewStyle(.linear)
                .tint(.green)
        }
    }
}

struct LockScreenTorrentView: View {
    let activityState: TorrentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.to.line")
                    .foregroundColor(.green)
                Text(activityState.torrentName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(activityState.status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ProgressView(value: activityState.progress)
                .progressViewStyle(.linear)
                .tint(.green)
            HStack {
                Label(activityState.downloadSpeed, systemImage: "arrow.down")
                Label(activityState.uploadSpeed, systemImage: "arrow.up")
                Spacer()
                Text("\(activityState.downloadedSize) / \(activityState.totalSize)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .font(.caption)
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.7))
        .activitySystemActionForegroundColor(.white)
    }
}
