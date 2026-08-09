import SwiftUI

// MARK: - DownloadItemCard

public struct DownloadItemCard: View {
    public let task: DownloadTaskModel
    public let isSelectionMode: Bool
    public let isSelected: Bool
    public let onPause:           () -> Void
    public let onResume:          () -> Void
    public let onCancel:          () -> Void
    public let onRetry:           () -> Void
    public let onDelete:          () -> Void
    public let onShare:           () -> Void
    public let onChangePriority:  (DownloadPriority) -> Void
    public let onShowInfo:        () -> Void
    public let onUpdateURL:       () -> Void
    public let onShowMirrors:     () -> Void
    public let onShowDiagnostics: () -> Void
    public let onToggleSelect:    () -> Void

    public init(
        task:             DownloadTaskModel,
        isSelectionMode:  Bool                        = false,
        isSelected:       Bool                        = false,
        onPause:          @escaping () -> Void,
        onResume:         @escaping () -> Void,
        onCancel:         @escaping () -> Void,
        onRetry:          @escaping () -> Void,
        onDelete:         @escaping () -> Void,
        onShare:          @escaping () -> Void,
        onChangePriority: @escaping (DownloadPriority) -> Void,
        onShowInfo:       @escaping () -> Void        = {},
        onUpdateURL:      @escaping () -> Void        = {},
        onShowMirrors:    @escaping () -> Void        = {},
        onShowDiagnostics:@escaping () -> Void        = {},
        onToggleSelect:   @escaping () -> Void        = {}
    ) {
        self.task             = task
        self.isSelectionMode  = isSelectionMode
        self.isSelected       = isSelected
        self.onPause          = onPause
        self.onResume         = onResume
        self.onCancel         = onCancel
        self.onRetry          = onRetry
        self.onDelete         = onDelete
        self.onShare          = onShare
        self.onChangePriority = onChangePriority
        self.onShowInfo       = onShowInfo
        self.onUpdateURL      = onUpdateURL
        self.onShowMirrors    = onShowMirrors
        self.onShowDiagnostics = onShowDiagnostics
        self.onToggleSelect   = onToggleSelect
    }

    // MARK: Computed

    private var fileIconName: String {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "mp4", "mkv", "mov", "avi":      return "film.fill"
        case "mp3", "m4a", "wav", "flac":     return "music.note"
        case "pdf":                            return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo.fill"
        case "ipa":                            return "app.fill"
        default:                               return "doc.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .downloading: return .blue
        case .paused:      return .orange
        case .completed:   return .green
        case .failed:      return .red
        case .cancelled:   return .gray
        case .pending:     return .purple
        }
    }

    private var hasMirrors: Bool { !task.mirrors.isEmpty }
    private var isOnMirror: Bool { task.currentMirrorIndex > 0 }

    // MARK: Body

    public var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                progressSection
                errorSection
                Divider().padding(.vertical, 2)
                actionRow
            }
        }
        // Long-press context menu
        .contextMenu { contextMenuContent }
        // Tap-to-select when in selection mode
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode { onToggleSelect() }
        }
        // Selection overlay
        .overlay(alignment: .topLeading) {
            if isSelectionMode {
                selectionBadge
                    .padding(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .opacity(isSelectionMode && !isSelected ? 0.65 : 1.0)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            // File type icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: fileIconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.filename)
                        .font(.headline)
                        .lineLimit(1)
                    // Mirror indicator badge
                    if isOnMirror {
                        Text("Mirror \(task.currentMirrorIndex)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(task.activeURL.host ?? task.activeURL.absoluteString)
                        .lineLimit(1)
                    if task.priority != .normal {
                        Text("• \(task.priority.description)")
                            .fontWeight(.bold)
                            .foregroundStyle(task.priority == .high ? Color.red : Color.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(title: task.status.rawValue, color: statusColor)
        }
    }

    // MARK: Progress

    @ViewBuilder
    private var progressSection: some View {
        if task.status == .downloading || task.status == .paused || task.status == .pending {
            VStack(spacing: 6) {
                ProgressView(value: task.progress)
                    .tint(statusColor)

                HStack {
                    Text("\(task.formattedDownloadedSize) / \(task.formattedTotalSize)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if task.status == .downloading {
                        HStack(spacing: 6) {
                            Text(task.formattedSpeed)
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)

                            if task.averageSpeedBytesPerSec > 0 {
                                Text("avg \(task.formattedAverageSpeed)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text("• ETA \(task.formattedETA)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Error

    @ViewBuilder
    private var errorSection: some View {
        if let errorMsg = task.errorMessage, task.status == .failed {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
                Spacer()
                Button(action: onShowDiagnostics) {
                    Text("Details")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(8)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Action Row

    private var actionRow: some View {
        HStack(spacing: 12) {
            // Primary action
            primaryActionButton

            // Update Link for paused/failed
            if task.status == .paused || task.status == .failed {
                Button(action: onUpdateURL) {
                    Label("Update Link", systemImage: "link.badge.plus")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.purple)
            }

            // Cancel button
            if task.status == .downloading || task.status == .pending {
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Priority picker (non-completed)
            if task.status != .completed {
                Menu {
                    ForEach(DownloadPriority.allCases, id: \.rawValue) { p in
                        Button(action: { onChangePriority(p) }) {
                            HStack {
                                Text("Priority: \(p.description)")
                                if task.priority == p { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Info button
            Button(action: onShowInfo) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Delete
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if task.status == .downloading {
            Button(action: onPause) {
                Label("Pause", systemImage: "pause.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        } else if task.status == .paused || task.status == .pending {
            Button(action: onResume) {
                Label("Resume", systemImage: "play.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        } else if task.status == .failed || task.status == .cancelled {
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
        } else if task.status == .completed {
            Button(action: onShare) {
                Label("Share / Open", systemImage: "square.and.arrow.up")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    // MARK: Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(action: onShowInfo) {
            Label("Download Info", systemImage: "info.circle")
        }

        if task.status == .paused || task.status == .failed {
            Button(action: onUpdateURL) {
                Label("Update Link", systemImage: "link.badge.plus")
            }
        }

        Button(action: onShowMirrors) {
            Label("Manage Mirrors (\(task.mirrors.count))", systemImage: "server.rack")
        }

        if task.status == .failed {
            Button(action: onShowDiagnostics) {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }

        Divider()

        Button {
            UIPasteboard.general.string = task.url.absoluteString
        } label: {
            Label("Copy URL", systemImage: "doc.on.doc")
        }

        if task.status == .completed, task.destinationPath != nil {
            Button(action: onShare) {
                Label("Share / Open", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        Button(action: onToggleSelect) {
            Label("Select", systemImage: "checkmark.circle")
        }

        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Selection Badge

    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color(uiColor: .systemBackground).opacity(0.8))
                .frame(width: 22, height: 22)
                .shadow(radius: 1)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            }
        }
    }
}

// MARK: - Equatable wrapper (prevents unnecessary re-renders)

public struct EquatableDownloadItemCard: View, Equatable {
    public let task:             DownloadTaskModel
    public let isSelectionMode:  Bool
    public let isSelected:       Bool
    public let onPause:          () -> Void
    public let onResume:         () -> Void
    public let onCancel:         () -> Void
    public let onRetry:          () -> Void
    public let onDelete:         () -> Void
    public let onShare:          () -> Void
    public let onChangePriority: (DownloadPriority) -> Void
    public let onShowInfo:       () -> Void
    public let onUpdateURL:      () -> Void
    public let onShowMirrors:    () -> Void
    public let onShowDiagnostics:() -> Void
    public let onToggleSelect:   () -> Void

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.task            == rhs.task &&
        lhs.isSelectionMode == rhs.isSelectionMode &&
        lhs.isSelected      == rhs.isSelected
    }

    public var body: some View {
        DownloadItemCard(
            task:              task,
            isSelectionMode:   isSelectionMode,
            isSelected:        isSelected,
            onPause:           onPause,
            onResume:          onResume,
            onCancel:          onCancel,
            onRetry:           onRetry,
            onDelete:          onDelete,
            onShare:           onShare,
            onChangePriority:  onChangePriority,
            onShowInfo:        onShowInfo,
            onUpdateURL:       onUpdateURL,
            onShowMirrors:     onShowMirrors,
            onShowDiagnostics: onShowDiagnostics,
            onToggleSelect:    onToggleSelect
        )
    }
}
