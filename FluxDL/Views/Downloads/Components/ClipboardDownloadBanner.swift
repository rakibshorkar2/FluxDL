import SwiftUI

/// Downloads-tab clipboard prompt. Owned by DownloadsView — never overlays
/// Browser, Proxy, Settings or Torrent.
public struct ClipboardDownloadBanner: View {
    public let url: URL
    public let onDownload: () -> Void
    public let onDismiss: () -> Void

    public init(url: URL, onDownload: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.url = url
        self.onDownload = onDownload
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GlassCard(padding: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Link Copied to Clipboard")
                        .font(.caption.bold())
                    Text(url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onDownload) {
                    Text("Download")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
