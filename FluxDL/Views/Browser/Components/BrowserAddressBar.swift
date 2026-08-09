import SwiftUI

public struct BrowserAddressBar: View {
    @Binding var text: String
    let isLoading: Bool
    let progress: Double
    let isDesktopMode: Bool
    let onCommit: () -> Void
    let onReload: () -> Void
    let onToggleDesktop: () -> Void
    let onOpenPageActions: () -> Void
    
    @FocusState private var isFocused: Bool
    
    public var body: some View {
        VStack(spacing: 0) {
            GlassCard(padding: 6) {
                HStack(spacing: 8) {
                    // Page Actions / Desktop mode button
                    Button(action: onOpenPageActions) {
                        Image(systemName: isDesktopMode ? "desktopcomputer" : "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(isDesktopMode ? Color.purple : Color.accentColor)
                    }
                    
                    // URL / Search Input
                    HStack(spacing: 6) {
                        Image(systemName: text.hasPrefix("https") ? "lock.fill" : "globe")
                            .font(.caption2)
                            .foregroundStyle(text.hasPrefix("https") ? Color.green : Color.secondary)
                        
                        TextField("Search or enter web address...", text: $text)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isFocused)
                            .onSubmit {
                                isFocused = false
                                onCommit()
                            }
                        
                        if isLoading {
                            ProgressView().scaleEffect(0.6)
                        } else if !text.isEmpty {
                            Button(action: { text = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    // Reload / Stop button
                    Button(action: onReload) {
                        Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            
            // Linear loading progress bar
            if isLoading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .frame(height: 2)
            }
        }
    }
}
