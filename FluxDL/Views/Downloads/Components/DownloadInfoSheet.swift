import SwiftUI
import UniformTypeIdentifiers

// MARK: - DownloadInfoSheet

public struct DownloadInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let task: DownloadTaskModel

    // Live task updates via engine observation
    @ObservedObject private var liveEngine: DownloadEngine
    private var liveTask: DownloadTaskModel {
        liveEngine.tasks.first { $0.id == task.id } ?? task
    }

    @State private var computingChecksums = false
    @State private var checksumError: String?

    public init(task: DownloadTaskModel) {
        self.task = task
        self.liveEngine = ServiceContainer.shared.downloadEngine as! DownloadEngine
    }

    public var body: some View {
        NavigationStack {
            List {
                downloadSection
                httpSection
                mimeSection
                serverSection
                checksumSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Download Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: – Download Section

    private var downloadSection: some View {
        Section("Download") {
            InfoRow(label: "Filename",   value: liveTask.filename)
            InfoRow(label: "Primary URL", value: liveTask.url.absoluteString, copiable: true)
            if liveTask.currentMirrorIndex > 0 {
                InfoRow(label: "Active URL", value: liveTask.activeURL.absoluteString, copiable: true, accent: true)
            }
            InfoRow(label: "Status",     value: liveTask.status.rawValue)
            InfoRow(label: "Downloaded", value: "\(liveTask.formattedDownloadedSize) / \(liveTask.formattedTotalSize)")
            InfoRow(label: "Progress",   value: String(format: "%.1f%%", liveTask.progress * 100))
            if liveTask.status == .downloading {
                InfoRow(label: "Speed",      value: liveTask.formattedSpeed)
                InfoRow(label: "Avg Speed",  value: liveTask.formattedAverageSpeed)
                InfoRow(label: "ETA",        value: liveTask.formattedETA)
            }
            InfoRow(label: "Created",    value: formatDate(liveTask.createdAt))
            if let started = liveTask.startedAt {
                InfoRow(label: "Started",  value: formatDate(started))
            }
            if let completed = liveTask.completedAt {
                InfoRow(label: "Completed", value: formatDate(completed))
            }
            if let path = liveTask.destinationPath {
                InfoRow(label: "Destination", value: (path as NSString).lastPathComponent)
            }
            InfoRow(label: "Resume Support", value: liveTask.acceptsRanges ? "Yes" : "No")
            if let http = liveTask.lastHTTPStatusCode {
                InfoRow(label: "HTTP Status", value: "\(http)")
            }
            InfoRow(label: "Retries", value: "\(liveTask.retryCount) / \(liveTask.maxRetries)")
        }
    }

    // MARK: – HTTP Section

    private var httpSection: some View {
        Section("HTTP") {
            if let headers = liveTask.responseHeaders, !headers.isEmpty {
                let sortedKeys = headers.keys.sorted()
                ForEach(sortedKeys, id: \.self) { key in
                    InfoRow(label: key.capitalized, value: headers[key] ?? "—", copiable: true)
                }
            } else {
                Text("No response headers captured yet.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    // MARK: – MIME Section

    private var mimeSection: some View {
        Section("MIME") {
            if let mime = liveTask.mimeType {
                InfoRow(label: "MIME Type", value: mime, copiable: true)
                if let uti = UTType(mimeType: mime) {
                    InfoRow(label: "UTType", value: uti.identifier, copiable: true)
                    if let ext = uti.preferredFilenameExtension {
                        InfoRow(label: "Suggested Ext.", value: ".\(ext)")
                    }
                    InfoRow(label: "Category", value: detectedCategory(uti: uti))
                }
            } else {
                InfoRow(label: "MIME Type", value: inferredMIME)
                InfoRow(label: "Category",  value: inferredCategory)
            }
        }
    }

    // MARK: – Server Section

    private var serverSection: some View {
        Section("Server") {
            if let server = liveTask.serverName {
                InfoRow(label: "Server",        value: server)
            }
            InfoRow(label: "Redirect Count",    value: "\(liveTask.redirectCount)")
            InfoRow(label: "Range Support",     value: liveTask.acceptsRanges ? "Yes (bytes)" : "No")
            if let etag = liveTask.etag {
                InfoRow(label: "ETag",          value: etag, copiable: true)
            }
            if let lm = liveTask.lastModified {
                InfoRow(label: "Last-Modified", value: lm)
            }
        }
    }

    // MARK: – Checksum Section

    private var checksumSection: some View {
        Section("Checksums") {
            if liveTask.status == .completed, liveTask.destinationPath != nil {
                if let sha = liveTask.sha256Hash {
                    InfoRow(label: "SHA-256", value: sha, copiable: true)
                }
                if let md5 = liveTask.md5Hash {
                    InfoRow(label: "MD5", value: md5, copiable: true)
                }

                if liveTask.sha256Hash == nil || liveTask.md5Hash == nil {
                    if computingChecksums {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Computing checksums…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            computeChecksums()
                        } label: {
                            Label("Compute Checksums", systemImage: "checkmark.shield")
                        }
                    }
                }

                if let error = checksumError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if liveTask.status != .completed {
                Text("Checksums are computed after the download completes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("File not found on disk.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private var inferredMIME: String {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private var inferredCategory: String {
        let ext = (task.filename as NSString).pathExtension.lowercased()
        guard let uti = UTType(filenameExtension: ext) else { return "Unknown" }
        return detectedCategory(uti: uti)
    }

    private func detectedCategory(uti: UTType) -> String {
        if uti.conforms(to: .video)        { return "Video" }
        if uti.conforms(to: .audio)        { return "Audio" }
        if uti.conforms(to: .image)        { return "Image" }
        if uti.conforms(to: .pdf)          { return "PDF" }
        if uti.conforms(to: .archive)      { return "Archive" }
        if uti.conforms(to: .spreadsheet)  { return "Spreadsheet" }
        if uti.conforms(to: .presentation) { return "Presentation" }
        if uti.conforms(to: .text)         { return "Text" }
        if uti.conforms(to: .sourceCode)   { return "Source Code" }
        return "Other"
    }

    private func computeChecksums() {
        guard let engine = ServiceContainer.shared.downloadEngine as? DownloadEngine else { return }
        computingChecksums = true
        checksumError = nil
        let snapshot = liveTask
        Task.detached(priority: .utility) {
            await DownloadVerificationService.shared.computeAndStore(task: snapshot, engine: engine)
            await MainActor.run { computingChecksums = false }
        }
    }
}

// MARK: - InfoRow

private struct InfoRow: View {
    let label:    String
    let value:    String
    var copiable: Bool = false
    var accent:   Bool = false

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
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
                        .animation(.easeInOut(duration: 0.2), value: copied)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
