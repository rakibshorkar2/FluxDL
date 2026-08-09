import SwiftUI
import LibTorrent

// MARK: - State presentation helpers

extension TorrentHandle.State {
    public var displayTitle: String {
        switch self {
        case .checkingFiles: return "Checking Files"
        case .checkingResumeData: return "Checking Resume Data"
        case .downloadingMetadata: return "Fetching Metadata"
        case .downloading: return "Downloading"
        case .finished: return "Finished"
        case .seeding: return "Seeding"
        case .paused: return "Paused"
        case .storageError: return "Storage Error"
        }
    }

    public var displayIcon: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .storageError: return "exclamationmark.triangle.fill"
        case .checkingFiles, .checkingResumeData: return "magnifyingglass"
        case .downloadingMetadata: return "doc.text.magnifyingglass"
        }
    }

    public var displayColor: Color {
        switch self {
        case .downloading: return .blue
        case .seeding: return .green
        case .finished: return .green
        case .paused: return .orange
        case .storageError: return .red
        case .checkingFiles, .checkingResumeData: return .purple
        case .downloadingMetadata: return .purple
        }
    }
}

// MARK: - Byte formatting

public enum TorrentByteFormatter {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func rate(_ bytesPerSecond: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
    }
}

// MARK: - TorrentItemCard

public struct TorrentItemCard: View {
    public let torrent: TorrentTaskModel
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onRemove: (Bool) -> Void
    public let onShowDetail: () -> Void

    public init(
        torrent: TorrentTaskModel,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onRemove: @escaping (Bool) -> Void,
        onShowDetail: @escaping () -> Void
    ) {
        self.torrent = torrent
        self.onPause = onPause
        self.onResume = onResume
        self.onRemove = onRemove
        self.onShowDetail = onShowDetail
    }

    public var body: some View {
        GlassCard(padding: 14, cornerRadius: AppTheme.cornerRadiusMedium) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(torrent.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)

                        StatusBadge(
                            title: torrent.state.displayTitle,
                            icon: torrent.state.displayIcon,
                            color: torrent.state.displayColor
                        )
                    }

                    Spacer()

                    if !torrent.isFinished {
                        Text("\(Int(torrent.progress * 100))%")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                if torrent.total > 0 {
                    ProgressView(value: torrent.progress)
                        .tint(torrent.state == .storageError ? Color.red : Color.accentColor)
                }

                HStack(spacing: 12) {
                    if torrent.downloadRate > 0 {
                        Label(TorrentByteFormatter.rate(torrent.downloadRate), systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    if torrent.uploadRate > 0 {
                        Label(TorrentByteFormatter.rate(torrent.uploadRate), systemImage: "arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    if torrent.total > 0 {
                        Text("\(TorrentByteFormatter.string(torrent.totalDone)) / \(TorrentByteFormatter.string(torrent.total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if torrent.totalSeeds + torrent.totalPeers > 0 {
                        HStack(spacing: 6) {
                            Label("\(torrent.totalSeeds)", systemImage: "person.2.fill")
                            Label("\(torrent.totalPeers)", systemImage: "person.3.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onShowDetail)
            .contextMenu {
                if torrent.state == .paused || torrent.state == .storageError {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button(action: onPause) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                }

                Button("Remove (Keep Files)", role: .destructive) { onRemove(false) }
                Button("Remove & Delete Files", role: .destructive) { onRemove(true) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if torrent.state == .paused || torrent.state == .storageError {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .tint(.green)
                } else {
                    Button(action: onPause) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .tint(.orange)
                }

                Button(role: .destructive, action: { onRemove(false) }) {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}
