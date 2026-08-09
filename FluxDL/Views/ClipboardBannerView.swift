import SwiftUI
import UIKit

/// Window-level overlay replicating the smart clipboard banner from the SwiftUI
/// MainTabView. Sits above the tab bar and works across every tab.
struct ClipboardBannerView: View {
    @ObservedObject private var clipboardService: ClipboardService = (ServiceContainer.shared.clipboardService as? ClipboardService) ?? ClipboardService()

    let onDownload: (URL) -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            if let detectedURL = clipboardService.detectedURL {
                GlassCard(padding: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link Copied to Clipboard")
                                .font(.caption.bold())
                            Text(detectedURL.absoluteString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button(action: { onDownload(detectedURL) }) {
                            Text("Download")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)

                        Button(action: { clipboardService.dismissDetectedURL() }) {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(), value: clipboardService.detectedURL)
        .allowsHitTesting(clipboardService.detectedURL != nil)
    }
}
