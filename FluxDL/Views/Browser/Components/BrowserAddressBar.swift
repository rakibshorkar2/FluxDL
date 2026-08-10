import SwiftUI

/// Compact browser toolbar: Back, Forward, Home, address/search field,
/// tabs button and a host-provided "More" menu. Adapts to keyboards,
/// scrolling (chrome collapse), compact layouts and safe areas.
public struct BrowserAddressBar<MoreMenuContent: View>: View {
    @Binding var text: String
    let isLoading: Bool
    let progress: Double
    let canGoBack: Bool
    let canGoForward: Bool
    let tabCount: Int
    let onCommit: () -> Void
    let onReload: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onGoHome: () -> Void
    let onOpenTabs: () -> Void
    let onFocusChange: (Bool) -> Void
    let moreMenu: () -> MoreMenuContent
    
    @FocusState private var isFocused: Bool
    
    public init(
        text: Binding<String>,
        isLoading: Bool,
        progress: Double,
        canGoBack: Bool,
        canGoForward: Bool,
        tabCount: Int,
        onCommit: @escaping () -> Void,
        onReload: @escaping () -> Void,
        onGoBack: @escaping () -> Void,
        onGoForward: @escaping () -> Void,
        onGoHome: @escaping () -> Void,
        onOpenTabs: @escaping () -> Void,
        onFocusChange: @escaping (Bool) -> Void,
        @ViewBuilder moreMenu: @escaping () -> MoreMenuContent
    ) {
        self._text = text
        self.isLoading = isLoading
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.tabCount = tabCount
        self.onCommit = onCommit
        self.onReload = onReload
        self.onGoBack = onGoBack
        self.onGoForward = onGoForward
        self.onGoHome = onGoHome
        self.onOpenTabs = onOpenTabs
        self.onFocusChange = onFocusChange
        self.moreMenu = moreMenu
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            GlassCard(padding: 6) {
                HStack(spacing: 4) {
                    // Back
                    ToolbarButton(
                        systemImage: "chevron.backward",
                        isEnabled: canGoBack,
                        accessibilityLabel: "Go Back",
                        action: onGoBack
                    )
                    
                    // Forward
                    ToolbarButton(
                        systemImage: "chevron.forward",
                        isEnabled: canGoForward,
                        accessibilityLabel: "Go Forward",
                        action: onGoForward
                    )
                    
                    // Home
                    ToolbarButton(
                        systemImage: "house",
                        isEnabled: true,
                        accessibilityLabel: "Go Home",
                        action: onGoHome
                    )
                    
                    // Address / Search field
                    HStack(spacing: 6) {
                        Image(systemName: text.hasPrefix("https") ? "lock.fill" : "globe")
                            .font(.caption2)
                            .foregroundStyle(text.hasPrefix("https") ? Color.green : Color.secondary)
                            .accessibilityHidden(true)
                        
                        TextField("Search or enter web address...", text: $text)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isFocused)
                            .onSubmit {
                                isFocused = false
                                onCommit()
                            }
                            .accessibilityLabel("Address or search field")
                        
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.6)
                                .accessibilityHidden(true)
                        } else if !text.isEmpty {
                            Button(action: { text = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Clear address field")
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(minHeight: 30)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .layoutPriority(1)
                    
                    // Reload / Stop
                    ToolbarButton(
                        systemImage: isLoading ? "xmark" : "arrow.clockwise",
                        isEnabled: true,
                        accessibilityLabel: isLoading ? "Stop Loading" : "Reload",
                        action: onReload
                    )
                    
                    // Tabs button with count badge
                    Button(action: onOpenTabs) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5)
                                .frame(width: 24, height: 24)
                            Text("\(tabCount)")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tabs")
                    .accessibilityValue("\(tabCount) open tabs")
                    .disabled(tabCount == 0)
                    
                    // More menu
                    moreMenu()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .onChange(of: isFocused) { focused in
                onFocusChange(focused)
            }
            
            // Linear loading progress bar
            if isLoading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .frame(height: 2)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct ToolbarButton: View {
    let systemImage: String
    let isEnabled: Bool
    let accessibilityLabel: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel)
    }
}
