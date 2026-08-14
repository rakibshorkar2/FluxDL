import UIKit

public protocol HapticServiceProtocol: AnyObject {
    func selectionChanged()
    func impactOccurred(_ style: UIImpactFeedbackGenerator.FeedbackStyle)
    func notificationOccurred(_ type: UINotificationFeedbackGenerator.FeedbackType)
}

/// Global haptic policy: every FluxDL haptic call site funnels through this
/// service, so `Settings → Haptic Feedback` controls all of them. Each
/// emission re-reads the preference at the moment it fires, so a change takes
/// effect immediately — even inside in-flight async operations — with no
/// restart or view recreation required.
@MainActor
public final class HapticService: HapticServiceProtocol {
    /// Single source of truth for the preference key. The Settings UI
    /// references this constant instead of duplicating the literal, so the
    /// toggle and the emission gate can never drift apart.
    public static let hapticsEnabledKey = "fluxdl_haptics_enabled"

    private let selectionGenerator = UISelectionFeedbackGenerator()

    /// Whether FluxDL-generated haptic feedback is currently permitted.
    /// Unset defaults to enabled (the app's existing default).
    public var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.hapticsEnabledKey) != nil
            ? UserDefaults.standard.bool(forKey: Self.hapticsEnabledKey) : true
    }

    public init() {
        guard isEnabled else { return }
        selectionGenerator.prepare()
    }

    public func selectionChanged() {
        guard isEnabled else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    public func impactOccurred(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    public func notificationOccurred(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
