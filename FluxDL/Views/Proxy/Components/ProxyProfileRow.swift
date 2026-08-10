import SwiftUI

// MARK: - ProxyProfileRow

public struct ProxyProfileRow: View {
    public let profile: ProxyProfile
    public let isSelected: Bool
    public var onSelect: () -> Void
    public var onEdit: () -> Void
    public var onTest: () -> Void
    public var onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        profile: ProxyProfile,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onTest: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.profile = profile
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onTest = onTest
        self.onDelete = onDelete
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: isSelected ? 2 : 1
                        )
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 14, height: 14)
                    }
                }
                .accessibilityHidden(true)

                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: profile.configuration.type.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.configuration.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(profile.configuration.type.displayName)
                        Text("\u{2022}")
                        Text(profile.configuration.hostAndPortString)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    if profile.configuration.authenticationEnabled {
                        Label("Authenticated", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Status / latency
                VStack(alignment: .trailing, spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)

                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                }
                .accessibilityHidden(true)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? Color.accentColor.opacity(0.55)
                                    : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                                lineWidth: isSelected ? 1.5 : 0.8
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onTest) {
                Label("Test", systemImage: "bolt.fill")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
            Button(action: onTest) {
                Label("Test", systemImage: "bolt.fill")
            }
            .tint(.orange)
        }
        .accessibilityIdentifier("proxy.profileRow.\(profile.configuration.name)")
        .accessibilityLabel("\(profile.configuration.name), \(profile.configuration.type.displayName), \(profile.configuration.hostAndPortString), \(statusText)")
    }

    // MARK: Status

    private var statusColor: Color {
        guard profile.hasLastTest else { return .secondary }
        return profile.isLastTestConnected ? .green : .red
    }

    private var statusText: String {
        guard let latencyMs = profile.lastLatencyMs, profile.isLastTestConnected else {
            if let state = profile.lastConnectionState, state == .failed {
                return "Failed"
            }
            return "Not tested"
        }
        return "\(latencyMs) ms"
    }
}
