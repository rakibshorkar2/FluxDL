import SwiftUI

/// App-owned switch toggle style.
///
/// SwiftUI's native `.switch` style is backed by a UIKit `UISwitch`, which
/// emits its own system haptic on every flip — bypassing `HapticService` and
/// the global `Settings → Haptic Feedback` preference. This style replaces the
/// native switch with an identical-looking, fully app-owned SwiftUI switch
/// (same size, per-toggle tint, colors and spring animation), so no system
/// haptic is produced. Every flip is instead routed through `HapticService`,
/// the single source of truth: when haptics are OFF the flip is silent, when
/// ON it produces the usual light selection tick.
public struct AppToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            MainActor.assumeIsolated {
                ServiceContainer.shared.hapticService.selectionChanged()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                switchIndicator(isOn: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    private func switchIndicator(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(HierarchicalShapeStyle.tint) : AnyShapeStyle(offTrackColor))
            .frame(width: 51, height: 31)
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(isOn ? 1 : 0)
            }
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 27, height: 27)
                    .padding(2)
                    .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(AppTheme.quickSpring, value: isOn)
    }

    private var offTrackColor: Color {
        Color(uiColor: colorScheme == .dark ? .systemGray4 : .systemGray5)
    }
}