import SwiftUI

/// Reusable status pill badge component
public struct StatusBadge: View {
    private let title: String
    private let icon: String?
    private let color: Color
    
    public init(title: String, icon: String? = nil, color: Color = .blue) {
        self.title = title
        self.icon = icon
        self.color = color
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.caption2.bold())
            }
            Text(title)
                .font(.caption2.weight(.bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
    }
}
