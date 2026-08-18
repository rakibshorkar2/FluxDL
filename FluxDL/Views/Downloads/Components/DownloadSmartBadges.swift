import SwiftUI

// MARK: - DownloadHealthBadge

/// Compact health indicator for the Downloads tab (row + detail screens).
public struct DownloadHealthBadge: View {
    public let state: DownloadHealthState

    public init(state: DownloadHealthState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(color)
        }
        .accessibilityLabel("Download health: \(label)")
    }

    private var label: String { state.rawValue }

    private var color: Color {
        switch state {
        case .unknown:   return .secondary
        case .excellent: return .green
        case .good:      return .green
        case .degraded:  return .yellow
        case .poor:      return .orange
        case .stalled:   return .orange
        case .failed:    return .red
        }
    }
}

// MARK: - DownloadConnectionBadge

/// "4 connections" chip shown on downloading rows when the smart engine is
/// using multi-connection segmentation.
public struct DownloadConnectionBadge: View {
    public let connections: Int

    public init(connections: Int) {
        self.connections = connections
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "network")
                .font(.system(size: 9))
            Text(connections > 1 ? "\(connections)" : "1")
                .font(.caption2)
                .monospacedDigit()
            Text(connections > 1 ? "connections" : "connection")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

// MARK: - DownloadStrategyBadge

/// Strategy chip (Segmented / Standard / Resumable / …).
public struct DownloadStrategyBadge: View {
    public let strategy: DownloadStrategy?

    public init(strategy: DownloadStrategy?) {
        self.strategy = strategy
    }

    public var body: some View {
        if let strategy, strategy != .normal {
            Text(strategy.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
        }
    }
}