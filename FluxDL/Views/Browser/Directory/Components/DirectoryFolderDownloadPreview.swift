import SwiftUI

/// DirXplore-inspired folder download preview: shows the recursive crawl
/// results (file count, total size, per-file checkboxes with smart defaults)
/// before submitting a batch of downloads to the existing DownloadEngine.
public struct DirectoryFolderDownloadPreview: View {
    @ObservedObject var viewModel: DirectoryBrowserViewModel

    @State private var filterText: String = ""

    public init(viewModel: DirectoryBrowserViewModel) {
        self.viewModel = viewModel
    }

    private var request: DirectoryFolderDownloadRequest? {
        viewModel.folderDownloadRequest
    }

    private var visibleFiles: [CrawledFile] {
        guard let request else { return [] }
        guard !filterText.isEmpty else { return request.files }
        return request.files.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var totalBytes: Int64 {
        request?.files.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) } ?? 0
    }

    public var body: some View {
        NavigationView {
            Group {
                if let request, !request.wasCancelled, !request.files.isEmpty {
                    content(request: request)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Download Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.folderDownloadRequest = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        if let request = viewModel.folderDownloadRequest {
                            viewModel.downloadFolderPreview(request)
                        }
                    }
                    .disabled(request?.selectedFiles.isEmpty ?? true)
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: filterText) { newValue in
            viewModel.folderDownloadRequest?.filterText = newValue
        }
    }

    private func content(request: DirectoryFolderDownloadRequest) -> some View {
        VStack(spacing: 0) {
            summaryBar(request: request)
            filterBar
            Divider()
            fileList(request: request)
            footerBar(request: request)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No files were found")
                .font(.headline)
            if let request, request.wasCancelled {
                Text("The folder crawl was cancelled before it could finish.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            if let request, !request.failedFolders.isEmpty {
                Text("\(request.failedFolders.count) subfolder\(request.failedFolders.count == 1 ? "" : "s") could not be read")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryBar(request: DirectoryFolderDownloadRequest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.folderName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(request.files.count) files")
                    if request.foldersScanned > 0 {
                        Text("• \(request.foldersScanned) folder\(request.foldersScanned == 1 ? "" : "s")")
                    }
                    Text("• \(DirectoryItemFormatter.string(fromBytes: totalBytes) ?? "size unknown")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !request.failedFolders.isEmpty {
                Label("\(request.failedFolders.count) failed", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter files", text: $filterText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func fileList(request: DirectoryFolderDownloadRequest) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleFiles) { file in
                    fileRow(request: request, file: file)
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func fileRow(request: DirectoryFolderDownloadRequest, file: CrawledFile) -> some View {
        let isSelected = request.selectedIDs.contains(file.id)
        return Button {
            if isSelected {
                viewModel.folderDownloadRequest?.selectedIDs.remove(file.id)
            } else {
                viewModel.folderDownloadRequest?.selectedIDs.insert(file.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Image(systemName: file.type.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(file.type == .video ? Color.pink : Color.secondary)
                    .frame(width: 24)

                Text(file.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1...2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let size = file.sizeBytes {
                    Text(DirectoryItemFormatter.string(fromBytes: size) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footerBar(request: DirectoryFolderDownloadRequest) -> some View {
        HStack(spacing: 10) {
            Button {
                let allVisible = Set(visibleFiles.map(\.id))
                let allSelected = request.selectedIDs.isSuperset(of: allVisible)
                if allSelected {
                    viewModel.folderDownloadRequest?.selectedIDs.subtract(allVisible)
                } else {
                    viewModel.folderDownloadRequest?.selectedIDs.formUnion(allVisible)
                }
            } label: {
                Label(
                    request.selectedIDs.isSuperset(of: visibleFiles.map(\.id)) ? "Deselect All" : "Select All",
                    systemImage: request.selectedIDs.isSuperset(of: visibleFiles.map(\.id)) ? "checkmark.circle" : "circle"
                )
                .font(.subheadline)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(request.selectedFiles.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(DirectoryItemFormatter.string(fromBytes: request.totalSelectedBytes) ?? "0 B")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Presented while the recursive folder crawl is running. Dismissing it
/// cancels the scan; no download tasks are created when cancelled.
public struct DirectoryFolderScanProgressView: View {
    let folderName: String
    let progress: DirectoryCrawlProgress
    let onCancel: () -> Void

    public init(folderName: String, progress: DirectoryCrawlProgress, onCancel: @escaping () -> Void) {
        self.folderName = folderName
        self.progress = progress
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.accentColor)

                VStack(spacing: 6) {
                    Text("Scanning \(folderName)")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Recursively discovering files and subfolders…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 4) {
                    Text("\(progress.filesFound) files")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("\(progress.visitedFolders) folder\(progress.visitedFolders == 1 ? "" : "s") scanned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let current = progress.currentFolder, !current.isEmpty {
                        Text(current)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, 24)
                    }
                }

                Button("Cancel", role: .destructive) {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Folder Download")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        .presentationDetents([.medium])
    }
}