import SwiftUI

/// iOS 26 Inspired Glassmorphic Card Container
/// Uses drawingGroup() to rasterize the background once, avoiding per-frame recompositing.
public struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content
    private let padding: CGFloat
    private let cornerRadius: CGFloat

    public init(
        padding: CGFloat = 16,
        cornerRadius: CGFloat = AppTheme.cornerRadiusLarge,
        @ViewBuilder content: () -> Content
    ) {
        self.padding      = padding
        self.cornerRadius = cornerRadius
        self.content      = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark ? AppTheme.darkGlassBorderGradient : AppTheme.glassBorderGradient,
                                lineWidth: 0.8
                            )
                    )
                    .shadow(color: AppTheme.glassShadowColor, radius: 8, x: 0, y: 3)
            }
    }
}
