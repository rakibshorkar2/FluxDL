import Foundation
import Combine
import Network

// MARK: - BrowserProxySession
//
// Bridges the app's active proxy configuration into browser networking.
//
// WKWebView cannot be tunneled without VPN/private APIs, so browser traffic
// follows the same APPLICATION-LEVEL proxy rule as everything else in FluxDL:
// sessions are built through `ProxySessionProvider` using the native
// `Network.ProxyConfiguration` (iOS 17+) path — SOCKS4 is bridged by the
// local loopback adapter. Traffic from other apps is never affected, and
// once the proxy applies, `allowFailover` is false (no silent direct
// fallback — a failed proxy is a failed request).
//
// The state here is event-driven (Combine, no polling timer). When the
// effective route changes, `proxyDidChange` fires so consumers (the browser
// tab manager) can reload tabs and rebuild their session configuration.

@MainActor
public final class BrowserProxySession: ObservableObject {
    public static let shared = BrowserProxySession()

    /// True when the proxy is enabled AND the browser route is on.
    @Published public private(set) var isProxyActive: Bool = false
    /// "host:port" (IPv6 bracketed) for the toolbar indicator.
    @Published public private(set) var proxyLabel: String?
    /// The configuration currently applied to browser sessions.
    @Published public private(set) var activeConfiguration: ProxyConfiguration?

    /// Emitted every time the effective route changes (enable/disable/toggle).
    public let proxyDidChange = PassthroughSubject<Void, Never>()

    private let sessionProvider = ProxySessionProvider()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        guard let service = ServiceContainer.shared.proxyService as? ProxyService else { return }
        service.$isEnabled
            .combineLatest(service.$activeConfiguration, service.$browserProxyEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled, configuration, browserEnabled in
                self?.apply(
                    isEnabled: isEnabled,
                    configuration: configuration,
                    browserEnabled: browserEnabled
                )
            }
            .store(in: &cancellables)
        apply(
            isEnabled: service.isEnabled,
            configuration: service.activeConfiguration,
            browserEnabled: service.browserProxyEnabled
        )
    }

    private func apply(isEnabled: Bool, configuration: ProxyConfiguration?, browserEnabled: Bool) {
        let active = (isEnabled && browserEnabled) ? configuration : nil
        let didChange = activeConfiguration != active
        activeConfiguration = active
        isProxyActive = active != nil
        proxyLabel = active.map { "\($0.displayHost):\($0.port)" }
        if didChange {
            proxyDidChange.send()
        }
    }

    // MARK: - Session

    /// A URLSessionConfiguration with the active proxy applied through the
    /// native `Network.ProxyConfiguration` path. Favicon fetches and other
    /// browser-side URLSession traffic share this path with downloads.
    ///
    /// Returns nil when the browser route is requested but the proxy could
    /// NOT be applied (e.g. the local adapter failed to bind): callers must
    /// fail closed — a nil return is a blocked request, never a direct one.
    public func sessionConfiguration() -> URLSessionConfiguration? {
        let configuration = sessionProvider.sessionConfiguration(for: activeConfiguration)
        if activeConfiguration != nil, sessionProvider.lastApplyFailure != nil {
            return nil
        }
        return configuration
    }

    /// Always true for loopback: the local SOCKS4 adapter lives on
    /// 127.0.0.1 and must never be routed through itself.
    public func shouldBypassProxy(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    /// Compatibility entry point used by the browser toolbar indicator.
    public func refresh() {
        guard let service = ServiceContainer.shared.proxyService as? ProxyService else { return }
        apply(
            isEnabled: service.isEnabled,
            configuration: service.activeConfiguration,
            browserEnabled: service.browserProxyEnabled
        )
    }
}