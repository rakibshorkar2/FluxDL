import SwiftUI

/// Premium iOS 26 inspired theme design system for FluxDL
public enum AppTheme {
    // MARK: - Colors & Gradients
    public static let primaryGradient = LinearGradient(
        colors: [Color.blue, Color.purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    public static let accentGradient = LinearGradient(
        colors: [Color.cyan, Color.blue],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    public static let glassBorderGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.4),
            Color.white.opacity(0.1),
            Color.white.opacity(0.05)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    public static let darkGlassBorderGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.2),
            Color.white.opacity(0.05),
            Color.clear
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // MARK: - Corner Radius Tokens
    public static let cornerRadiusLarge: CGFloat = 24.0
    public static let cornerRadiusMedium: CGFloat = 16.0
    public static let cornerRadiusSmall: CGFloat = 12.0
    
    // MARK: - Shadows
    public static let glassShadowColor = Color.black.opacity(0.12)
    public static let glassShadowRadius: CGFloat = 16.0
    
    // MARK: - Animation Standards
    public static let defaultSpring = Animation.spring(response: 0.35, dampingFraction: 0.78, blendDuration: 0)
    public static let quickSpring = Animation.spring(response: 0.25, dampingFraction: 0.85, blendDuration: 0)
}
