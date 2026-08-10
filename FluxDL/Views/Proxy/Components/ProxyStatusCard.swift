import SwiftUI

// MARK: - ProxyStatusCard
//
// Prominent card communicating the current proxy state:
//   * Proxy Disabled
//   * Proxy Enabled (with type, host, port, connection state, latency)
//   * Testing...
//   * Connection Failed

public struct ProxyStatusCard: View {
    @ObservedObject public var service: ProxyService
    public var onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(service: ProxyService, onToggle: @escaping () -> Void) {
        self.service = service
        self.onToggle = onToggle
    }

    public var body: some View {
        GlassCard(padding: 18) {
            VStack(spacing: 14) {
                header

                if service.isEnabled, let configuration = service.activeConfiguration {
                    Divider()
                    details(configuration)
                } else if service.connectionState == .connecting || service.isTesting {
                    Divider()
                    testingRow
                }

                Divider()

                toggleButton
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(headerColor.opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(headerColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.headline)
                    .foregroundStyle(headerColor)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if service.connectionState == .connecting || service.isTesting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                StatusBadge(title: headerTitle, icon: statusIcon, color: headerColor)
            }
        }
    }

    private var headerTitle: String {
        if service.isTesting || service.connectionState == .connecting {
            return "Testing..."
        }
        switch service.connectionState {
        case .disabled:  return "Proxy Disabled"
        case .connecting: return "Testing..."
        case .connected: return "Proxy Enabled"
        case .failed:    return "Connection Failed"
        }
    }

    private var subtitle: String? {
        if service.isEnabled, let configuration = service.activeConfiguration {
            return "\(configuration.type.displayName) \u{2022} \(configuration.hostAndPortString)"
        }
        if service.connectionState == .failed {
            return service.lastFailureMessage ?? "The proxy could not be reached."
        }
        if service.connectionState == .disabled {
            return "Add a proxy below to route app downloads and browser traffic."
        }
        return nil
    }

    private var headerColor: Color {
        if service.connectionState == .connected { return .green }
        if service.connectionState == .failed { return .red }
        if service.connectionState == .connecting || service.isTesting { return .orange }
        return .secondary
    }

    private var statusIcon: String? {
        switch service.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .connecting: return nil
        case .disabled:  return "power"
        }
    }

    // MARK: Details

    private func details(_ configuration: ProxyConfiguration) -> some View {
        VStack(spacing: 10) {
            detailRow(label: "Type", value: configuration.type.displayName, icon: "network")
            detailRow(label: "Host", value: configuration.host, icon: "server.rack")
            detailRow(label: "Port", value: "\(configuration.port)", icon: "number")
            detailRow(
                label: "Connection",
                value: connectionText,
                icon: "bolt.fill",
                valueColor: service.connectionState == .connected ? .green : .red
            )
            detailRow(label: "Latency", value: latencyText, icon: "timer", valueColor: .secondary)
        }
    }

    private var connectionText: String {
        switch service.connectionState {
        case .connected:  return "Connected"
        case .failed:     return "Failed"
        case .connecting: return "Connecting..."
        case .disabled:   return "Disabled"
        }
    }

    private var latencyText: String {
        guard service.connectionState == .connected, let latencyMs = service.activeLatencyMs else {
            return "—"
        }
        return "\(latencyMs) ms"
    }

    private func detailRow(label: String, value: String, icon: String, valueColor: Color = .primary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }

    private var testingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Testing connection...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: Toggle

    private var toggleButton: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: service.isEnabled ? "power" : "power.circle.fill")
                Text(service.isEnabled ? "Disable Proxy" : "Enable Proxy")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                service.isEnabled ? Color.red.opacity(0.14) : Color.green.opacity(0.14),
                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
            )
            .foregroundStyle(service.isEnabled ? Color.red : Color.green)
        }
        .buttonStyle(.plain)
        .disabled(!service.isEnabled && service.selectedProfileID == nil)
        .opacity(!service.isEnabled && service.selectedProfileID == nil ? 0.4 : 1)
        .accessibilityIdentifier("proxy.enableButton")
        .accessibilityLabel(service.isEnabled ? "Disable proxy" : "Enable proxy")
    }

    private var accessibilitySummary: String {
        var parts = [headerTitle]
        if service.isEnabled, let configuration = service.activeConfiguration {
            parts.append("\(configuration.type.displayName), host \(configuration.host), port \(configuration.port)")
            parts.append(connectionText)
            if service.connectionState == .connected, let latencyMs = service.activeLatencyMs {
                parts.append("\(latencyMs) milliseconds")
            }
        }
        return parts.joined(separator: ". ")
    }
}
