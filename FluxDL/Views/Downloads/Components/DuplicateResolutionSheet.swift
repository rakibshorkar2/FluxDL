import SwiftUI

// MARK: - DuplicateResolutionSheet

/// Presented when the user tries to add a URL that already exists in the queue.
public struct DuplicateResolutionSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let newURL: URL
    public let existingTask: DownloadTaskModel?
    public let onResolve: (DuplicateResolutionOption) -> Void

    public init(
        newURL: URL,
        existingTask: DownloadTaskModel?,
        onResolve: @escaping (DuplicateResolutionOption) -> Void
    ) {
        self.newURL       = newURL
        self.existingTask = existingTask
        self.onResolve    = onResolve
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Header ───────────────────────────────────────────────
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 64, height: 64)
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                    }

                    Text("Duplicate Download")
                        .font(.title2.bold())

                    Text("A download with this URL already exists in your queue.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)

                // ── Existing task info ───────────────────────────────────
                if let existing = existingTask {
                    HStack(spacing: 12) {
                        statusIcon(for: existing.status)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(existing.filename)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text(existing.status.rawValue + " • " + existing.formattedDownloadedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }

                // ── Options ───────────────────────────────────────────────
                VStack(spacing: 12) {
                    // Resume Existing (if applicable)
                    if let existing = existingTask,
                       existing.status == .paused || existing.status == .failed {
                        ResolutionButton(
                            icon: "play.circle.fill",
                            title: "Resume Existing",
                            subtitle: "Continue the paused/failed download",
                            color: .green
                        ) {
                            onResolve(.resumeExisting)
                            dismiss()
                        }
                    }

                    // Skip
                    ResolutionButton(
                        icon: "xmark.circle",
                        title: "Skip",
                        subtitle: "Don't add the new download",
                        color: .secondary
                    ) {
                        onResolve(.skip)
                        dismiss()
                    }

                    // Keep Both
                    ResolutionButton(
                        icon: "plus.circle.fill",
                        title: "Keep Both",
                        subtitle: "Add as a separate download",
                        color: .blue
                    ) {
                        onResolve(.keepBoth)
                        dismiss()
                    }

                    // Replace
                    ResolutionButton(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Replace",
                        subtitle: "Delete existing and start fresh",
                        color: .red
                    ) {
                        onResolve(.replace)
                        dismiss()
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onResolve(.skip)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for status: DownloadStatus) -> some View {
        let color: Color = {
            switch status {
            case .downloading: return .blue
            case .paused:      return .orange
            case .completed:   return .green
            case .failed:      return .red
            case .cancelled:   return .gray
            case .pending:     return .purple
            }
        }()
        ZStack {
            Circle().fill(color.opacity(0.15)).frame(width: 36, height: 36)
            Image(systemName: "doc.fill").foregroundStyle(color).font(.callout)
        }
    }
}

// MARK: - ResolutionButton

private struct ResolutionButton: View {
    let icon:     String
    let title:    String
    let subtitle: String
    let color:    Color
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
