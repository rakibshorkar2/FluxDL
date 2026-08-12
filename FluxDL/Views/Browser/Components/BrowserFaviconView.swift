import SwiftUI

/// Displays a site favicon (via the Google favicon service) with a fallback
/// letter avatar when the image can't be loaded or the host is unknown.
public struct BrowserFaviconView: View {
    let url: URL?
    let fallbackText: String
    var size: CGFloat = 16
    
    private static let cache = NSCache<NSString, UIImage>()
    
    @State private var image: UIImage?
    
    public init(url: URL?, fallbackText: String, size: CGFloat = 16) {
        self.url = url
        self.fallbackText = fallbackText
        self.size = size
    }
    
    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                    Text(String(fallbackText.prefix(1)).uppercased())
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: load)
        .onChange(of: url) { _ in
            image = nil
            load()
        }
    }
    
    private func load() {
        let target: URL
        if let url, let host = url.host {
            // Google's favicon service is reliable and avoids CORS issues.
            target = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")!
        } else {
            return
        }
        
        let key = target.absoluteString as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        
        Task {
            guard let session = await Self.makeSession() else { return }
            guard let (data, _) = try? await session.data(from: target),
                  let fetched = UIImage(data: data) else { return }
            session.finishTasksAndInvalidate()
            Self.cache.setObject(fetched, forKey: key)
            await MainActor.run {
                image = fetched
            }
        }
    }

    /// Short-lived session routed through the browser's proxy (direct when
    /// no proxy is active; rebuilt on every route change). Returns nil when
    /// the proxy route is requested but unusable — the fetch fails closed
    /// (letter avatar) instead of going direct.
    @MainActor
    private static func makeSession() async -> URLSession? {
        guard let config = BrowserProxySession.shared.sessionConfiguration() else { return nil }
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}
