import SwiftUI

/// The "Add Torrent?" popup for magnet links and remote `.torrent` files.
/// Visually consistent with `BrowserDownloadPromptView`; uses semantic
/// colors, materials and strokes only, so it adapts instantly to Light /
/// Dark / System appearance.
public struct BrowserTorrentPromptView: View {
    public let prompt: BrowserTorrentPrompt
    public let isLoading: Bool
    public let errorMessage: String?
    public let onAdd: () -> Void
    public let onCancel: () -> Void

    public init(
        prompt: BrowserTorrentPrompt,
        isLoading: Bool,
        errorMessage: String?,
        onAdd: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onAdd = onAdd
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Add Torrent?")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 4) {
                    Text(prompt.kindLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if prompt.kind == .magnet {
                        if let hash = prompt.infoHash {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(hashLabel(hash))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if prompt.trackerCount > 0 {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("\(prompt.trackerCount) tracker\(prompt.trackerCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching torrent metadata…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            HStack {
                Button(action: onAdd) {
                    Text("Add Torrent")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .opacity(isLoading ? 0.6 : 1)
                .accessibilityLabel("Add torrent")

                Spacer()

                Button("Cancel", action: onCancel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(isLoading)
                    .accessibilityLabel("Cancel add torrent")
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
    }

    /// Compact hash display: first 8 + last 8 hex characters.
    private func hashLabel(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(8))…\(hash.suffix(8))"
    }
}
