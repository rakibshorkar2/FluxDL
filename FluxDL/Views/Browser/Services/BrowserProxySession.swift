import Foundation

/// Bridges the app's active proxy configuration into browser networking.
///
/// WKWebView does not honor `URLSessionConfiguration.connectionProxyDictionary`
/// directly; instead we expose the resolved proxy so the browser layer can
/// apply it to a URLSession used for pre-loads / favicon fetches, and publish
/// the human-readable proxy status for the toolbar indicator.
@MainActor
public final class BrowserProxySession: ObservableObject {
    public static let shared = BrowserProxySession()
    
    @Published public private(set) var isProxyActive: Bool = false
    @Published public private(set) var proxyLabel: String?
    
    private var timer: Timer?
    
    private init() {
        refresh()
    }
    
    /// The resolved proxy configuration currently in effect, if enabled.
    public var activeConfiguration: ProxyConfiguration? {
        ServiceContainer.shared.proxyService.activeConfiguration
    }
    
    /// A URLSessionConfiguration with the proxy applied. Use for background
    /// fetches (e.g. favicon downloads) so they share the proxy path.
    public func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        if let proxy = activeConfiguration {
            config.connectionProxyDictionary = Self.proxyDictionary(for: proxy)
        }
        return config
    }
    
    /// True when the URL host should bypass the proxy (local hosts / loopback).
    public func shouldBypassProxy(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return host == "localhost" || host.hasPrefix("127.") || host == "0.0.0.0"
    }
    
    public func refresh() {
        let proxy = ServiceContainer.shared.proxyService.activeConfiguration
        isProxyActive = proxy != nil
        proxyLabel = proxy.map { "\($0.host):\($0.port)" }
        scheduleRefresh()
    }
    
    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
    
    private static func proxyDictionary(for configuration: ProxyConfiguration) -> [AnyHashable: Any] {
        let host = configuration.host
        let port = configuration.port
        
        var dict: [AnyHashable: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": port
        ]
        
        // Authenticated proxies: only supported for HTTP(S) via the URLSession
        // delegate; here we just flag it for the browser session.
        if let password = configuration.password, !password.isEmpty {
            dict["__FLUXDL_AUTHENTICATED"] = true
        }
        
        return dict
    }
}
