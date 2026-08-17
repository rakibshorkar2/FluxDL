import SwiftUI

// MARK: - DownloadDiagnosticsSheet

public struct DownloadDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let task: DownloadTaskModel

    @State private var report: DiagnosticsReport?
    @State private var isLoading = true
    @State private var copied = false

    public init(task: DownloadTaskModel) {
        self.task = task
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let report {
                    reportView(report)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let report {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = report.plainText
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(
                                copied ? "Copied!" : "Copy",
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                            .animation(.easeInOut(duration: 0.2), value: copied)
                        }
                    }
                }
            }
            .task {
                report = await DownloadDiagnosticsService.shared.diagnose(task: task)
                isLoading = false
            }
        }
    }

    // MARK: Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Generating Diagnostics…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Report

    @ViewBuilder
    private func reportView(_ r: DiagnosticsReport) -> some View {
        List {
            // ── Overview ────────────────────────────────────────────────
            Section("Overview") {
                DiagRow(label: "Filename",   value: r.filename)
                DiagRow(label: "Status",     value: r.status.rawValue,
                        color: statusColor(r.status))
                if let http = r.httpStatus {
                    DiagRow(label: "HTTP Status", value: "\(http)",
                            color: http >= 400 ? .red : .primary)
                }
                if let code = r.errorCode {
                    DiagRow(label: "Error Code", value: "\(code)", color: .red)
                }
            }

            // ── Failure Details ──────────────────────────────────────────
            Section("Failure Details") {
                if let reason = r.failureReason {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Failure Reason")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 4)
                } else {
                    DiagRow(label: "Failure Reason", value: "None")
                }
                if let netErr = r.networkError {
                    DiagRow(label: "Network Error", value: netErr, color: .orange)
                }
            }

            // ── Resume / Retry ───────────────────────────────────────────
            Section("Resume & Retry") {
                DiagRow(label: "Can Resume",      value: r.canResume ? "Yes" : "No",
                        color: r.canResume ? .green : .orange)
                DiagRow(label: "Range Support",   value: r.rangeSupported ? "Yes (bytes)" : "No")
                DiagRow(label: "Last Good Byte",  value: ByteCountFormatter.string(
                    fromByteCount: r.lastSuccessfulByte, countStyle: .file))
                DiagRow(label: "Retry Count",     value: "\(r.retryCount) / \(r.maxRetries)")
            }

            // ── Suggested Fix ────────────────────────────────────────────
            Section("Suggested Fix") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                        Text(r.suggestedFix)
                            .font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
            }

            // ── Retry History ────────────────────────────────────────────
            if !r.retryHistory.isEmpty {
                Section("Retry History") {
                    ForEach(Array(r.retryHistory.enumerated()), id: \.offset) { i, record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Attempt \(i + 1)")
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(record.date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let msg = record.errorMessage {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if let http = record.httpStatus {
                                Text("HTTP \(http)")
                                    .font(.caption2)
                                    .foregroundStyle(http >= 400 ? .red : .secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // ── Meta ─────────────────────────────────────────────────────
            Section {
                DiagRow(label: "Generated", value: r.generatedAt.formatted(date: .abbreviated, time: .shortened))
                DiagRow(label: "Task ID",   value: r.taskID.uuidString, copiable: true)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func statusColor(_ status: DownloadStatus) -> Color {
        switch status {
        case .downloading: return .blue
        case .completed:   return .green
        case .failed:      return .red
        case .cancelled:   return .gray
        case .paused:      return .orange
        case .pending:     return .purple
        }
    }
}

// MARK: - DiagRow

private struct DiagRow: View {
    let label:    String
    let value:    String
    var color:    Color    = .primary
    var copiable: Bool     = false

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(3)

            if copiable {
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
