import SwiftUI
import LibTorrent

// MARK: - State presentation helpers

extension TorrentHandle.State {
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
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    public static func rate(_ bytesPerSecond: Int64) -> String {
        let clamped = max(0, bytesPerSecond)
        if clamped == 0 { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: clamped, countStyle: .binary) + "/s"
    }

    /// Compact ETA. Invalid, negative or absurdly large inputs render as "—".
    public static func eta(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < 60 * 60 * 24 * 365 else { return "—" }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// Spoken form for VoiceOver, e.g. "57 kilobytes per second".
    public static func spokenRate(_ bytesPerSecond: Int64) -> String {
        let clamped = max(0, bytesPerSecond)
        switch clamped {
        case 0: return "zero"
        case 1..<(1_024): return "\(clamped) bytes per second"
        case 1_024..<(1_024 * 1_024): return "\(clamped / 1_024) kilobytes per second"
        case (1_024 * 1_024)..<(1_024 * 1_024 * 1_024): return "\(clamped / (1_024 * 1_024)) megabytes per second"
        default: return "\(clamped / (1_024 * 1_024 * 1_024)) gigabytes per second"
        }
    }

    /// Spoken form of a byte count for VoiceOver.
    public static func spokenBytes(_ bytes: Int64) -> String {
        let clamped = max(0, bytes)
        switch clamped {
        case 0: return "zero bytes"
        case 1..<(1_024): return "\(clamped) bytes"
        case 1_024..<(1_024 * 1_024): return "\(clamped / 1_024) kilobytes"
        case (1_024 * 1_024)..<(1_024 * 1_024 * 1_024): return "\(clamped / (1_024 * 1_024)) megabytes"
        default: return "\(clamped / (1_024 * 1_024 * 1_024)) gigabytes"
        }
    }
}

// MARK: - TorrentItemCard

public struct TorrentItemCard: View {
    public let torrent: TorrentTaskModel
    public let isDeleting: Bool
    public let isSelectionMode: Bool
    public let isSelected: Bool
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onRemove: (Bool) -> Void
    public let onShowDetail: () -> Void
    public let onToggleSelection: () -> Void

    public init(
        torrent: TorrentTaskModel,
        isDeleting: Bool = false,
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onRemove: @escaping (Bool) -> Void,
        onShowDetail: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void = {}
    ) {
        self.torrent = torrent
        self.isDeleting = isDeleting
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onPause = onPause
        self.onResume = onResume
        self.onRemove = onRemove
        self.onShowDetail = onShowDetail
        self.onToggleSelection = onToggleSelection
    }

    public var body: some View {
        GlassCard(padding: 14, cornerRadius: AppTheme.cornerRadiusMedium) {
            if isDeleting {
                deletingContent
            } else {
                normalContent
            }
        }
    }

    // MARK: - Deleting state

    private var deletingContent: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(torrent.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text("Deleting files…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if torrent.total > 0 {
                Text(TorrentByteFormatter.string(torrent.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Normal state

    private var normalContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Name + percentage ────────────────────────────────────────
            HStack(alignment: .top, spacing: 10) {
                if isSelectionMode {
                    selectionIndicator
                }

                Text(torrent.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let percent = percentageText {
                    Text(percent)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                }
            }

            // ── Status + pause/resume ────────────────────────────────────
            HStack(spacing: 10) {
                StatusBadge(
                    title: torrent.statusTitle,
                    icon: statusIcon,
                    color: statusColor
                )

                Spacer(minLength: 8)

                if !isSelectionMode {
                    playPauseButton
                }
            }

            // ── Progress ─────────────────────────────────────────────────
            if torrent.total > 0 {
                ProgressView(value: torrent.clampedProgress)
                    .tint(torrent.state == .storageError ? Color.red : Color.accentColor)
            }

            // ── Speeds + ETA ─────────────────────────────────────────────
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
                if torrent.state == .downloading {
                    Text("ETA \(etaText)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
            }

            // ── Size + peers ─────────────────────────────────────────────
            HStack(spacing: 10) {
                if torrent.total > 0 {
                    Text("\(TorrentByteFormatter.string(torrent.totalDone)) / \(TorrentByteFormatter.string(torrent.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Spacer(minLength: 4)

                if torrent.state == .seeding || torrent.isSeed {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                        Text("\(max(0, torrent.seeds)) seeds")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !torrent.isFinished {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.fill")
                            Text("\(max(0, torrent.peers))")
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "person.3.fill")
                            Text("\(max(0, torrent.seeds))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onToggleSelection()
            } else {
                onShowDetail()
            }
        }
        .contextMenu {
            if isSelectionMode {
                Button {
                    onToggleSelection()
                } label: {
                    Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "checkmark.circle" : "circle")
                }
            } else {
                if isResumable {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button(action: onPause) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                }

                Divider()

                Button {
                    copyMagnet()
                } label: {
                    Label("Copy Magnet Link", systemImage: "doc.on.doc")
                }

                Button {
                    onShowDetail()
                } label: {
                    Label("View Details", systemImage: "info.circle")
                }

                Divider()

                Button("Remove (Keep Files)", role: .destructive) { onRemove(false) }
                Button("Remove & Delete Files", role: .destructive) { onRemove(true) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: { onRemove(false) }) {
                Label("Delete", systemImage: "trash")
            }

            if isResumable {
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(torrent.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isSelectionMode ? "Double tap to toggle selection" : "Double tap to open details")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Helpers

    private var isResumable: Bool {
        torrent.isPaused || torrent.state == .storageError
    }

    private var percentageText: String? {
        guard torrent.total > 0, !torrent.isFinished else { return nil }
        return "\(torrent.displayPercentage)%"
    }

    private var etaText: String {
        guard let eta = torrent.eta else { return "—" }
        return TorrentByteFormatter.eta(eta)
    }

    private var statusIcon: String {
        torrent.isStalled ? "exclamationmark.triangle.fill" : torrent.state.displayIcon
    }

    private var statusColor: Color {
        torrent.isStalled ? .orange : torrent.state.displayColor
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }

    private func copyMagnet() {
        guard let magnet = torrent.magnetLink else { return }
        UIPasteboard.general.string = magnet
    }

    /// VoiceOver summary, e.g. "Downloading, 3 percent complete, 57 kilobytes
    /// per second download, 5 kilobytes per second upload, ETA 1 hour 50
    /// minutes, 2 peers, 0 seeds".
    private var accessibilityValue: String {
        var parts: [String] = []
        let status = torrent.statusTitle.lowercased()
        switch status {
        case "stalled": parts.append("Stalled, no download progress")
        case "paused": parts.append("Paused")
        case "completed", "seeding": parts.append(status.capitalized)
        default: parts.append(status.capitalized)
        }
        parts.append("\(torrent.displayPercentage) percent complete")
        if torrent.downloadRate > 0 {
            parts.append("\(TorrentByteFormatter.spokenRate(torrent.downloadRate)) download")
        }
        if torrent.uploadRate > 0 {
            parts.append("\(TorrentByteFormatter.spokenRate(torrent.uploadRate)) upload")
        }
        if let eta = torrent.eta, eta.isFinite {
            parts.append("ETA \(etaText)")
        }
        if !torrent.isFinished {
            parts.append("\(max(0, torrent.peers)) peers, \(max(0, torrent.seeds)) seeds")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Play / pause button

    private var playPauseButton: some View {
        Button {
            if isResumable {
                onResume()
            } else {
                onPause()
            }
        } label: {
            Image(systemName: isResumable ? "play.fill" : "pause.fill")
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
                .foregroundStyle(Color.white)
                .background(
                    isResumable ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.orange)
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isResumable ? "Resume" : "Pause")
        .contentShape(Circle())
    }
}