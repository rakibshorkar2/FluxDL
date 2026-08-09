import UIKit

public protocol HapticServiceProtocol: AnyObject {
    func selectionChanged()
    func impactOccurred(_ style: UIImpactFeedbackGenerator.FeedbackStyle)
    func notificationOccurred(_ type: UINotificationFeedbackGenerator.FeedbackType)
}

@MainActor
public final class HapticService: HapticServiceProtocol {
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let hapticsKey = "fluxdl_haptics_enabled"
    
    private var isHapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsKey) != nil
            ? UserDefaults.standard.bool(forKey: hapticsKey) : true
    }
    
    public init() {
        selectionGenerator.prepare()
    }
    
    public func selectionChanged() {
        guard isHapticsEnabled else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }
    
    public func impactOccurred(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isHapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    public func notificationOccurred(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isHapticsEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
