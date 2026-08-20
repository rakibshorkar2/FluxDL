import SwiftUI

// MARK: - FolderDownloadGroupCard

/// Expandable card for a folder download group: header with aggregate
/// byte-weighted progress + a chevron, a collapsible child list with
/// per-child actions, and a group context menu (pause/resume/retry/cancel/
/// remove). Child downloads are individual `DownloadTaskModel`s owned by the
/// existing DownloadEngine; this card only renders them.
public struct FolderDownloadGroupCard: View {
    public let snapshot: FolderGroupSnapshot
    public let isExpanded: Bool
    public let onToggleExpanded: () -> Void

    public let onPauseGroup: () -> Void
    public let onResumeGroup: () -> Void
    public let onRetryGroup: () -> Void
    public let onCancelGroup: () -> Void
    /// Parameter = `deleteFiles`.
    public let onRemoveGroup: (Bool) -> Void

    public let onPauseChild: (UUID) -> Void
    public let onResumeChild: (UUID) -> Void
    public let onRetryChild: (UUID) -> Void
    public let onCancelChild: (UUID) -> Void
    public let onDeleteChild: (UUID, Bool) -> Void
    /// Detaches a child from the folder group (task stays in Downloads).
    public let onRemoveChild: (UUID) -> Void

    /// Row-local confirmation state for "Remove Folder".
    @State private var showingRemovePopup = false

    public init(
        snapshot: FolderGroupSnapshot,
        isExpanded: Bool,
        onToggleExpanded: @escaping () -> Void,
        onPauseGroup: @escaping () -> Void = {},
        onResumeGroup: @escaping () -> Void = {},
        onRetryGroup: @escaping () -> Void = {},
        onCancelGroup: @escaping () -> Void = {},
        onRemoveGroup: @escaping (Bool) -> Void = { _ in },
        onPauseChild: @escaping (UUID) -> Void = { _ in },
        onResumeChild: @escaping (UUID) -> Void = { _ in },
        onRetryChild: @escaping (UUID) -> Void = { _ in },
        onCancelChild: @escaping (UUID) -> Void = { _ in },
        onDeleteChild: @escaping (UUID, Bool) -> Void = { _, _ in },
        onRemoveChild: @escaping (UUID) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.isExpanded = isExpanded
        self.onToggleExpanded = onToggleExpanded
        self.onPauseGroup = onPauseGroup
        self.onResumeGroup = onResumeGroup
        self.onRetryGroup = onRetryGroup
        self.onCancelGroup = onCancelGroup
        self.onRemoveGroup = onRemoveGroup
        self.onPauseChild = onPauseChild
        self.onResumeChild = onResumeChild
        self.onRetryChild = onRetryChild
        self.onCancelChild = onCancelChild
        self.onDeleteChild = onDeleteChild
        self.onRemoveChild = onRemoveChild
    }

    // MARK: Computed

    private var stateColor: Color {
        switch snapshot.state {
        case .scanning:          return .gray
        case .queued:            return .purple
        case .downloading:       return .blue
        case .paused:            return .orange
        case .partiallyCompleted: return .orange
        case .completed:         return .green
        case .failed:            return .red
        case .cancelled:         return .gray
        }
    }

    private var showsProgressBar: Bool {
        switch snapshot.state {
        case .scanning, .completed, .failed, .cancelled:
            return false
        case .queued, .downloading, .paused, .partiallyCompleted:
            return true
        }
    }

    private var primaryAction: (icon: String, action: () -> Void)? {
        switch snapshot.state {
        case .downloading, .queued:
            return ("pause.fill", onPauseGroup)
        case .paused:
            return ("play.fill", onResumeGroup)
        case .failed, .partiallyCompleted:
            return ("arrow.clockwise", onRetryGroup)
        default:
            return nil
        }
    }

    // MARK: Body

    public var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if showsProgressBar {
                    progressSection
                }
                if snapshot.failedCount > 0 {
                    Text("\(snapshot.failedCount) file\(snapshot.failedCount == 1 ? "" : "s") failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if isExpanded && !snapshot.children.isEmpty {
                    Divider()
                    childList
                }
            }
        }
        .confirmationDialog(
            "Remove Folder \(snapshot.group.name)?",
            isPresented: $showingRemovePopup,
            titleVisibility: .visible
        ) {
            Button("Delete Files & Records", role: .destructive) {
                onRemoveGroup(true)
            }
            Button("Remove from List Only", role: .destructive) {
                onRemoveGroup(false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting files also removes the folder's files from Downloads.")
        }
        .contextMenu { contextMenuContent }
    }

    // MARK: Header

    private var header: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(stateColor.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(stateColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.group.name)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(snapshot.detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    StatusBadge(title: snapshot.state.title, color: stateColor)
                    Text(snapshot.completionSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(spacing: 6) {
            ProgressView(value: snapshot.progress)
                .tint(stateColor)

            HStack {
                Text(snapshot.progressLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()

                Spacer()

                if let action = primaryAction {
                    Button(action: action.action) {
                        Image(systemName: action.icon)
                            .font(.caption.bold())
                            .frame(width: 26, height: 26)
                            .background(stateColor.opacity(0.15), in: Circle())
                            .foregroundStyle(stateColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Folder primary action")
                }
            }
        }
    }

    // MARK: Child List

    private var childList: some View {
        VStack(spacing: 0) {
            ForEach(snapshot.children) { child in
                childRow(child)
                if child.id != snapshot.children.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func childRow(_ child: FolderChildSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: childStatusIcon(child))
                .font(.caption)
                .foregroundStyle(childStatusColor(child))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(child.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let directory = child.displayDirectory {
                    Text(directory)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(ByteCountFormatter.string(fromByteCount: child.task.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: childSize(child), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(child.task.status.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(childStatusColor(child))
            }

            Menu {
                childActions(child)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func childActions(_ child: FolderChildSnapshot) -> some View {
        switch child.task.status {
        case .downloading, .pending:
            Button { onPauseChild(child.id) } label: {
                Label("Pause", systemImage: "pause.fill")
            }
        case .paused:
            Button { onResumeChild(child.id) } label: {
                Label("Resume", systemImage: "play.fill")
            }
        case .failed, .cancelled:
            Button { onRetryChild(child.id) } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        case .completed:
            Button { onDeleteChild(child.id, true) } label: {
                Label("Delete File", systemImage: "trash")
            }
        }
        if child.task.status != .completed {
            Button { onDeleteChild(child.id, false) } label: {
                Label("Remove from List", systemImage: "xmark.circle")
            }
        }
        Button { onRemoveChild(child.id) } label: {
            Label("Remove from Folder", systemImage: "folder.badge.minus")
        }
    }

    // MARK: Context Menu

    private var contextMenuContent: some View {
        Group {
            switch snapshot.state {
            case .downloading, .queued:
                Button(action: onPauseGroup) {
                    Label("Pause Folder", systemImage: "pause.fill")
                }
            case .paused:
                Button(action: onResumeGroup) {
                    Label("Resume Folder", systemImage: "play.fill")
                }
            case .failed, .partiallyCompleted:
                Button(action: onRetryGroup) {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
            default:
                EmptyView()
            }

            if snapshot.state != .completed {
                Button(action: onCancelGroup) {
                    Label("Cancel Folder", systemImage: "xmark.octagon")
                }
            }

            Button(role: .destructive) {
                showingRemovePopup = true
            } label: {
                Label("Remove Folder", systemImage: "folder.badge.minus")
            }
        }
    }

    // MARK: Helpers

    private func childSize(_ child: FolderChildSnapshot) -> Int64 {
        max(child.task.totalBytes, child.task.downloadedBytes, child.expectedSize ?? 0)
    }

    private func childStatusIcon(_ child: FolderChildSnapshot) -> String {
        switch child.task.status {
        case .downloading: return "arrow.down.circle.fill"
        case .pending:     return "clock.fill"
        case .paused:      return "pause.circle.fill"
        case .completed:   return "checkmark.circle.fill"
        case .failed:      return "xmark.circle.fill"
        case .cancelled:   return "minus.circle"
        }
    }

    private func childStatusColor(_ child: FolderChildSnapshot) -> Color {
        switch child.task.status {
        case .downloading: return .blue
        case .pending:     return .purple
        case .paused:      return .orange
        case .completed:   return .green
        case .failed:      return .red
        case .cancelled:   return .gray
        }
    }
}
