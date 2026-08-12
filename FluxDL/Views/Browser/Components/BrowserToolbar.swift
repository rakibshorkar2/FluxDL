import SwiftUI

/// Stable bottom browser toolbar: Back | Forward | Share | Tabs | More.
///
/// It is attached to the browser chrome via the view's safe-area inset (never
/// floats over the webpage), uses standard iOS toolbar material for
/// readability, and is automatically pushed above the software keyboard.
public struct BrowserToolbar<MoreMenuContent: View>: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let tabCount: Int
    let onBack: () -> Void
    let onForward: () -> Void
    let onShare: () -> Void
    let onOpenTabs: () -> Void
    @ViewBuilder let moreMenu: () -> MoreMenuContent

    public init(
        canGoBack: Bool,
        canGoForward: Bool,
        tabCount: Int,
        onBack: @escaping () -> Void,
        onForward: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onOpenTabs: @escaping () -> Void,
        @ViewBuilder moreMenu: @escaping () -> MoreMenuContent
    ) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.tabCount = tabCount
        self.onBack = onBack
        self.onForward = onForward
        self.onShare = onShare
        self.onOpenTabs = onOpenTabs
        self.moreMenu = moreMenu
    }

    public var body: some View {
        HStack(spacing: 2) {
            BrowserChromeButton(
                systemImage: "chevron.backward",
                isEnabled: canGoBack,
                accessibilityLabel: "Go Back",
                action: onBack
            )

            BrowserChromeButton(
                systemImage: "chevron.forward",
                isEnabled: canGoForward,
                accessibilityLabel: "Go Forward",
                action: onForward
            )

            BrowserChromeButton(
                systemImage: "square.and.arrow.up",
                isEnabled: true,
                accessibilityLabel: "Share",
                action: onShare
            )

            tabsButton

            moreMenu()
                .frame(width: 44, height: 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var tabsButton: some View {
        Button(action: onOpenTabs) {
            HStack(spacing: 5) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 15, weight: .medium))
                Text("\(tabCount)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tabCount == 0)
        .opacity(tabCount == 0 ? 0.4 : 1)
        .accessibilityLabel("Tabs")
        .accessibilityValue("\(tabCount) open tabs")
    }
}

/// Shared icon button for the browser chrome (top bar and bottom toolbar).
public struct BrowserChromeButton: View {
    let systemImage: String
    let isEnabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    public init(
        systemImage: String,
        isEnabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel)
    }
}
