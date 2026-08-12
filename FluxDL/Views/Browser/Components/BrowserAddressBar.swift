import SwiftUI
import UIKit

/// Professional address bar, attached to the browser chrome (never floating
/// over the webpage).
///
/// Two distinct states:
/// - Display (not editing): favicon + security indicator + the hostname
///   rendered prominently; the reload/stop button sits on the right.
/// - Editing (focused): the full URL is revealed in a focused field whose
///   text is selected, a clear button appears, and submitting performs a
///   search or navigation. The keyboard never hides the bar because the
///   whole chrome is part of the safe-area layout.
public struct BrowserAddressBar: View {
    @Binding var text: String
    @Binding var isFieldFocused: Bool
    let displayHost: String
    let isLoading: Bool
    let progress: Double
    let faviconURL: URL?
    let isSecure: Bool
    let blockedCount: Int
    let suggestions: [URLSuggestion]
    let onCommit: () -> Void
    let onReload: () -> Void
    let onFocusChange: (Bool) -> Void
    let onSelectSuggestion: (URLSuggestion) -> Void
    let onClearSuggestions: () -> Void

    @FocusState private var isFocused: Bool

    private var isEditing: Bool { isFocused }

    private var fallbackLetter: String {
        let host = URL(string: text)?.host ?? ""
        return String((host.isEmpty ? text : host).prefix(1)).uppercased()
    }

    private var displayText: String {
        if !displayHost.isEmpty { return displayHost }
        return text.isEmpty ? "Search or enter web address" : text
    }

    public init(
        text: Binding<String>,
        isFieldFocused: Binding<Bool> = .constant(false),
        displayHost: String,
        isLoading: Bool,
        progress: Double,
        faviconURL: URL? = nil,
        isSecure: Bool = false,
        blockedCount: Int = 0,
        suggestions: [URLSuggestion] = [],
        onCommit: @escaping () -> Void,
        onReload: @escaping () -> Void,
        onFocusChange: @escaping (Bool) -> Void,
        onSelectSuggestion: @escaping (URLSuggestion) -> Void = { _ in },
        onClearSuggestions: @escaping () -> Void = {}
    ) {
        self._text = text
        self._isFieldFocused = isFieldFocused
        self.displayHost = displayHost
        self.isLoading = isLoading
        self.progress = progress
        self.faviconURL = faviconURL
        self.isSecure = isSecure
        self.blockedCount = blockedCount
        self.suggestions = suggestions
        self.onCommit = onCommit
        self.onReload = onReload
        self.onFocusChange = onFocusChange
        self.onSelectSuggestion = onSelectSuggestion
        self.onClearSuggestions = onClearSuggestions
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                field

                BrowserChromeButton(
                    systemImage: isLoading ? "xmark" : "arrow.clockwise",
                    isEnabled: true,
                    accessibilityLabel: isLoading ? "Stop Loading" : "Reload",
                    action: onReload
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if isLoading, progress > 0, progress < 1 {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(2, geo.size.width * progress))
                }
                .frame(height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
                .animation(.linear(duration: 0.15), value: progress)
                .transition(.opacity)
                .accessibilityHidden(true)
            }

            if isEditing && !suggestions.isEmpty {
                suggestionsPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(AppTheme.quickSpring, value: suggestions)
        .onChange(of: isFocused) { focused in
            isFieldFocused = focused
            onFocusChange(focused)
            if focused {
                selectAllText()
            } else {
                onClearSuggestions()
            }
        }
        .onChange(of: isFieldFocused) { focused in
            if !focused, isFocused { isFocused = false }
        }
    }

    // MARK: - Address field

    private var field: some View {
        ZStack(alignment: .trailing) {
            // Field surface
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isEditing ? Color.accentColor.opacity(0.7) : Color.clear,
                            lineWidth: 1.5
                        )
                )

            // Display mode: favicon + security + hostname (prominent).
            HStack(spacing: 6) {
                BrowserFaviconView(url: faviconURL ?? URL(string: text), fallbackText: fallbackLetter, size: 15)
                    .accessibilityHidden(true)

                Image(systemName: isSecure ? "lock.fill" : "lock.open")
                    .font(.caption2)
                    .foregroundStyle(isSecure ? Color.green : Color.orange)
                    .accessibilityLabel(isSecure ? "Secure connection" : "Not secure")

                Text(displayText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else if blockedCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "eye.slash.fill")
                        Text("\(blockedCount)")
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .accessibilityLabel("\(blockedCount) blocked requests")
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .allowsHitTesting(false)
            .opacity(isEditing ? 0 : 1)

            // Editing mode: real URL/search input.
            HStack(spacing: 6) {
                TextField("Search or enter web address", text: $text)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($isFocused)
                    .onSubmit {
                        isFocused = false
                        onCommit()
                    }
                    .accessibilityLabel("Address or search field")

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address field")
                }
            }
            .padding(.horizontal, 10)
            .allowsHitTesting(isEditing)
            .opacity(isEditing ? 1 : 0)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing { isFocused = true }
        }
    }

    // MARK: - Autocomplete suggestions

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: AppTheme.glassShadowColor, radius: AppTheme.glassShadowRadius, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Keyboard helpers

    /// Selects the whole URL so the user can type or replace it immediately.
    private func selectAllText() {
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
    }
}
