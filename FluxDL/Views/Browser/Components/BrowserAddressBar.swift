import SwiftUI

/// Browser toolbar with a Liquid Glass treatment: it collapses to a compact
/// pill while scrolling and expands (back/forward/home + suggestion panel)
/// when the address field is focused.
public struct BrowserAddressBar<MoreMenuContent: View>: View {
    @Binding var text: String
    @Binding var isFieldFocused: Bool
    let isLoading: Bool
    let progress: Double
    let canGoBack: Bool
    let canGoForward: Bool
    let tabCount: Int
    let faviconURL: URL?
    let isSecure: Bool
    let blockedCount: Int
    let suggestions: [URLSuggestion]
    let onCommit: () -> Void
    let onReload: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onGoHome: () -> Void
    let onOpenTabs: () -> Void
    let onFocusChange: (Bool) -> Void
    let onSelectSuggestion: (URLSuggestion) -> Void
    let onClearSuggestions: () -> Void
    let moreMenu: () -> MoreMenuContent
    
    @FocusState private var isFocused: Bool
    
    public init(
        text: Binding<String>,
        isFieldFocused: Binding<Bool> = .constant(false),
        isLoading: Bool,
        progress: Double,
        canGoBack: Bool,
        canGoForward: Bool,
        tabCount: Int,
        faviconURL: URL? = nil,
        isSecure: Bool = false,
        blockedCount: Int = 0,
        suggestions: [URLSuggestion] = [],
        onCommit: @escaping () -> Void,
        onReload: @escaping () -> Void,
        onGoBack: @escaping () -> Void,
        onGoForward: @escaping () -> Void,
        onGoHome: @escaping () -> Void,
        onOpenTabs: @escaping () -> Void,
        onFocusChange: @escaping (Bool) -> Void,
        onSelectSuggestion: @escaping (URLSuggestion) -> Void = { _ in },
        onClearSuggestions: @escaping () -> Void = {},
        @ViewBuilder moreMenu: @escaping () -> MoreMenuContent
    ) {
        self._text = text
        self._isFieldFocused = isFieldFocused
        self.isLoading = isLoading
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.tabCount = tabCount
        self.faviconURL = faviconURL
        self.isSecure = isSecure
        self.blockedCount = blockedCount
        self.suggestions = suggestions
        self.onCommit = onCommit
        self.onReload = onReload
        self.onGoBack = onGoBack
        self.onGoForward = onGoForward
        self.onGoHome = onGoHome
        self.onOpenTabs = onOpenTabs
        self.onFocusChange = onFocusChange
        self.onSelectSuggestion = onSelectSuggestion
        self.onClearSuggestions = onClearSuggestions
        self.moreMenu = moreMenu
    }
    
    private var isExpanded: Bool { isFocused || !suggestions.isEmpty }
    
    private var fallbackLetter: String {
        let host = URL(string: text)?.host ?? ""
        return String((host.isEmpty ? text : host).prefix(1)).uppercased()
    }
    
    public var body: some View {
        VStack(spacing: 6) {
            GlassCard(padding: 6) {
                HStack(spacing: 4) {
                    // Navigation controls only appear in the expanded state.
                    if isExpanded {
                        ToolbarButton(
                            systemImage: "chevron.backward",
                            isEnabled: canGoBack,
                            accessibilityLabel: "Go Back",
                            action: onGoBack
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        
                        ToolbarButton(
                            systemImage: "chevron.forward",
                            isEnabled: canGoForward,
                            accessibilityLabel: "Go Forward",
                            action: onGoForward
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        
                        ToolbarButton(
                            systemImage: "house",
                            isEnabled: true,
                            accessibilityLabel: "Go Home",
                            action: onGoHome
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                    
                    // Address / Search field
                    HStack(spacing: 6) {
                        if faviconURL != nil || !text.isEmpty {
                            BrowserFaviconView(url: faviconURL ?? URL(string: text), fallbackText: fallbackLetter, size: 14)
                                .accessibilityHidden(true)
                        }
                        
                        Image(systemName: isSecure ? "lock.fill" : "lock.open")
                            .font(.caption2)
                            .foregroundStyle(isSecure ? Color.green : Color.orange)
                            .accessibilityLabel(isSecure ? "Secure connection" : "Not secure")
                        
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
                    .background(
                        Color.primary.opacity(isExpanded ? 0.08 : 0.05),
                        in: RoundedRectangle(cornerRadius: isExpanded ? 10 : 16, style: .continuous)
                    )
                    .layoutPriority(1)
                    
                    // Blocked-request badge for the current page
                    if blockedCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "eye.slash.fill")
                            Text("\(blockedCount)")
                                .monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .accessibilityLabel("\(blockedCount) blocked requests")
                        .transition(.opacity)
                    }
                    
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
                .animation(AppTheme.quickSpring, value: isExpanded)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .onChange(of: isFocused) { focused in
                isFieldFocused = focused
                onFocusChange(focused)
            }
            .onChange(of: isFieldFocused) { focused in
                if !focused, isFocused { isFocused = false }
            }
            
            // Autocomplete suggestions panel (expanded + focused state)
            if isExpanded && !suggestions.isEmpty {
                suggestionsPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
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
        .animation(AppTheme.quickSpring, value: suggestions)
    }
    
    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Suggestions")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClearSuggestions) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss suggestions")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            ForEach(suggestions) { suggestion in
                Button(action: { onSelectSuggestion(suggestion) }) {
                    HStack(spacing: 8) {
                        BrowserFaviconView(url: URL(string: suggestion.urlString), fallbackText: suggestion.title, size: 16)
                        
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(suggestion.urlString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer(minLength: 0)
                        
                        Image(systemName: suggestion.kind == .bookmark ? "bookmark.fill" : "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: AppTheme.glassShadowColor, radius: AppTheme.glassShadowRadius, y: 4)
        .padding(.horizontal, 8)
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
