import SwiftUI

/// The "Download File?" popup, shown anchored to the exact element that
/// triggered the download. Uses semantic colors, materials and strokes only,
/// so it adapts instantly to Light / Dark / System appearance.
public struct BrowserDownloadPromptView: View {
    public let request: BrowserDownloadRequest
    public let onDownload: () -> Void
    public let onCancel: () -> Void

    public init(request: BrowserDownloadRequest, onDownload: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onDownload = onDownload
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Download File?")
                    .font(.headline)
            }

            Text("Detected downloadable file:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(request.displayFilename)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack {
                Button(action: onDownload) {
                    Text("Download Now")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download now")

                Spacer()

                Button("Cancel", action: onCancel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel download")
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
}