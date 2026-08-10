import Foundation
import Network
import Combine

/// Monitors device network connectivity and publishes changes so the browser
/// can react (show offline states, reload on reconnect, etc.).
@MainActor
public final class BrowserConnectivityMonitor: ObservableObject {
    public static let shared = BrowserConnectivityMonitor()
    
    public static let connectivityDidChangeNotification = Notification.Name("FluxDLBrowserConnectivityDidChange")
    
    @Published public private(set) var isConnected: Bool = true
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.fluxdl.browser.connectivity")
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.update(path: path)
            }
        }
        monitor.start(queue: queue)
    }
    
    private func update(path: NWPath) {
        let connected = path.status == .satisfied
        guard connected != isConnected else { return }
        isConnected = connected
        NotificationCenter.default.post(
            name: Self.connectivityDidChangeNotification,
            object: nil,
            userInfo: ["isConnected": connected]
        )
    }
}
