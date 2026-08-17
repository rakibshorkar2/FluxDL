import SwiftUI

/// Full-screen error state shown when a page fails to load (offline, DNS,
/// certificate errors, timeouts, etc.).
public struct BrowserErrorView: View {
    let url: URL?
    let message: String
    let onRetry: () -> Void
    
    public init(url: URL?, message: String, onRetry: @escaping () -> Void) {
        self.url = url
        self.message = message
        self.onRetry = onRetry
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("Page Couldn't Load")
                .font(.title3.bold())
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            if let url, let host = url.host {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Button(action: onRetry) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
