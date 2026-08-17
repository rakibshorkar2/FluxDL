import SwiftUI

// MARK: - DownloadHistoryView

public struct DownloadHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var historyManager: DownloadHistoryManager
    @StateObject private var viewModel: DownloadHistoryViewModel

    public init(
        historyManager: DownloadHistoryManager,
        onRetry: @escaping (DownloadHistoryEntry) -> Void
    ) {
        self.historyManager = historyManager
        _viewModel = StateObject(wrappedValue: DownloadHistoryViewModel(
            historyManager: historyManager,
            onRetry: onRetry
        ))
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                if historyManager.entries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationTitle("Download History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { navigationToolbar }
            .confirmationDialog(
                "Delete History Record?",
                isPresented: deleteBinding,
                titleVisibility: .visible
            ) {
                Button("Delete Record", role: .destructive) {
                    if let entry = viewModel.pendingDelete {
                        viewModel.remove(entry)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only removes the history entry. It does not delete the downloaded file or the download itself.")
            }
            .confirmationDialog(
                "Clear Download History?",
                isPresented: $isClearAllPresented,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    viewModel.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every history record.")
            }
        }
    }

    // MARK: List

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(HistorySection.build(from: historyManager.entries)) { section in
                    historySection(section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func historySection(_ section: HistorySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 4)

            ForEach(section.entries) { entry in
                historyRow(entry)
            }
        }
    }

    private func historyRow(_ entry: DownloadHistoryEntry) -> some View {
        let color = statusColor(entry.status)
        let isCopied = viewModel.copiedEntryID == entry.id

        return GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: fileIconName(for: entry.filename))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(color)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.filename)
                            .font(.headline)
                            .lineLimit(1)
                        Text(entry.displayHost)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    StatusBadge(title: entry.status.rawValue, color: color)
                }

                // Meta line
                HStack(spacing: 8) {
                    Label(entry.dateAdded.formatted(date: .abbreviated, time: .shortened),
                          systemImage: "calendar")
                    if entry.completedAt != nil {
                        Label("Completed", systemImage: "checkmark.circle")
                    }
                    if entry.totalBytes > 0 || entry.downloadedBytes > 0 {
                        Label(entry.formattedTotalSize, systemImage: "internaldrive")
                    }
                    if let mime = entry.mimeType, !mime.isEmpty {
                        Label(mime, systemImage: "doc.badge.ellipsis")
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                // Actions
                HStack(spacing: 10) {
                    Button {
                        viewModel.copyURL(entry)
                    } label: {
                        Label(isCopied ? "Copied" : "Copy Link",
                              systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(isCopied ? .green : Color.accentColor)

                    if entry.status != .downloading && entry.status != .pending {
                        Button {
                            viewModel.retry(entry)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()

                    Menu {
                        Button {
                            viewModel.copyURL(entry)
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                        }
                        Button {
                            viewModel.retry(entry)
                        } label: {
                            Label("Start / Retry Download", systemImage: "arrow.clockwise")
                        }
                        Button {
                            viewModel.shareURL(entry)
                        } label: {
                            Label("Share URL", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            viewModel.pendingDelete = entry
                        } label: {
                            Label("Delete Record", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            Button {
                viewModel.copyURL(entry)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            Button {
                viewModel.retry(entry)
            } label: {
                Label("Start / Retry Download", systemImage: "arrow.clockwise")
            }
            Button {
                viewModel.shareURL(entry)
            } label: {
                Label("Share URL", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                viewModel.pendingDelete = entry
            } label: {
                Label("Delete Record", systemImage: "trash")
            }
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("No Download History")
                    .font(.headline)

                Text("Downloads you start will be recorded here with their original links, so you can copy or retry them anytime.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
        }

        if !historyManager.entries.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isClearAllPresented = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Clear History")
            }
        }
    }

    // MARK: State helpers

    @State private var isClearAllPresented = false

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDelete != nil },
            set: { if !$0 { viewModel.pendingDelete = nil } }
        )
    }

    // MARK: Style helpers

    private func statusColor(_ status: DownloadStatus) -> Color {
        switch status {
        case .downloading: return .blue
        case .paused:      return .orange
        case .completed:   return .green
        case .failed:      return .red
        case .cancelled:   return .gray
        case .pending:     return .purple
        }
    }

    private func fileIconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "mp4", "mkv", "mov", "avi":      return "film.fill"
        case "mp3", "m4a", "wav", "flac":     return "music.note"
        case "pdf":                            return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo.fill"
        case "ipa":                            return "app.fill"
        default:                               return "doc.fill"
        }
    }
}

// MARK: - HistorySection

private struct HistorySection: Identifiable {
    let id: String
    let title: String
    let entries: [DownloadHistoryEntry]

    static func build(from entries: [DownloadHistoryEntry]) -> [HistorySection] {
        let calendar = Calendar.current
        var buckets: [(date: Date, title: String, entries: [DownloadHistoryEntry])] = []

        for entry in entries {
            if calendar.isDateInToday(entry.dateAdded) {
                if let idx = buckets.firstIndex(where: { $0.title == "Today" }) {
                    buckets[idx].entries.append(entry)
                } else {
                    buckets.append((date: calendar.startOfDay(for: entry.dateAdded), title: "Today", entries: [entry]))
                }
            } else if calendar.isDateInYesterday(entry.dateAdded) {
                if let idx = buckets.firstIndex(where: { $0.title == "Yesterday" }) {
                    buckets[idx].entries.append(entry)
                } else {
                    buckets.append((date: calendar.startOfDay(for: entry.dateAdded), title: "Yesterday", entries: [entry]))
                }
            } else {
                let day = calendar.startOfDay(for: entry.dateAdded)
                let title = entry.dateAdded.formatted(date: .abbreviated, time: .omitted)
                if let idx = buckets.firstIndex(where: { $0.title == title }) {
                    buckets[idx].entries.append(entry)
                } else {
                    buckets.append((date: day, title: title, entries: [entry]))
                }
            }
        }

        return buckets
            .sorted { $0.date > $1.date }
            .map {
                HistorySection(
                    id: $0.title,
                    title: $0.title,
                    entries: $0.entries.sorted { $0.dateAdded > $1.dateAdded }
                )
            }
    }
}
