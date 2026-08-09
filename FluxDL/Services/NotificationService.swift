import UserNotifications
import Foundation

public protocol NotificationServiceProtocol: AnyObject {
    func requestAuthorization() async
    func notifyDownloadCompleted(filename: String)
    func notifyDownloadFailed(filename: String, reason: String)
    func cancelAllNotifications()
}

public final class NotificationService: NotificationServiceProtocol {
    private let center = UNUserNotificationCenter.current()
    private let categoryIdentifier = "com.rakib.FluxDL.download"
    private let showNotificationsKey = "fluxdl_show_notifications"
    
    private var isNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: showNotificationsKey) != nil
            ? UserDefaults.standard.bool(forKey: showNotificationsKey) : true
    }
    
    public init() {}
    
    public func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                print("FluxDL: Notification permission granted.")
            }
        } catch {
            print("FluxDL: Notification authorization error: \(error.localizedDescription)")
        }
    }
    
    public func notifyDownloadCompleted(filename: String) {
        guard isNotificationsEnabled else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = "\(filename) has been saved to your Downloads."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        
        let request = UNNotificationRequest(
            identifier: "fluxdl-completed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        center.add(request) { error in
            if let error = error {
                print("FluxDL: Failed to schedule completion notification: \(error.localizedDescription)")
            }
        }
    }
    
    public func notifyDownloadFailed(filename: String, reason: String) {
        guard isNotificationsEnabled else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Download Failed"
        content.body = "\(filename) could not be downloaded. \(reason)"
        content.sound = .defaultCritical
        content.categoryIdentifier = categoryIdentifier
        
        let request = UNNotificationRequest(
            identifier: "fluxdl-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        center.add(request) { error in
            if let error = error {
                print("FluxDL: Failed to schedule failure notification: \(error.localizedDescription)")
            }
        }
    }
    
    public func cancelAllNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
