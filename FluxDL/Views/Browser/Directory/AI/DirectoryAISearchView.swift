import SwiftUI

/// Global AI search over the indexed Open Directory root.
///
/// Additive to the existing Directory Mode: the `Filter files` bar keeps its
/// current-directory behavior unchanged; this sheet searches the whole tree.
public struct DirectoryAISearchView: View {
    @ObservedObject var viewModel: DirectoryAISearchViewModel
    @Environment(\.dismiss) private var dismiss

    let onOpenResult: (DirectorySearchResult) -> Void
    let onDownload: (DirectoryItem) -> Void
    let onPlay: (DirectoryItem) -> Void
    let onShare: (DirectoryItem) -> Void
    let onCopyName: (DirectoryItem) -> Void
    let onBookmark: (DirectoryItem) -> Void

    private let haptics = ServiceContainer.shared.hapticService

    public init(
        viewModel: DirectoryAISearchViewModel,
        onOpenResult: @escaping (DirectorySearchResult) -> Void,
        onDownload: @escaping (DirectoryItem) -> Void,
        onPlay: @escaping (DirectoryItem) -> Void,
        onShare: @escaping (DirectoryItem) -> Void,
        onCopyName: @escaping (DirectoryItem) -> Void,
        onBookmark: @escaping (DirectoryItem) -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenResult = onOpenResult
        self.onDownload = onDownload
        self.onPlay = onPlay
        self.onShare = onShare
        self.onCopyName = onCopyName
        self.onBookmark = onBookmark
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchField
                statusBar
                if let message = viewModel.aiMessage {
                    banner(message)
                }
                Divider()
                resultsList
            }
            .navigationTitle("Search Entire Directory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { viewModel.ensureIndex() }
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            DirectoryAISearchSettingsView(viewModel: viewModel)
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Search files...", text: $viewModel.searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { viewModel.submit() }
                .accessibilityLabel("Search files in the entire directory")

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.searchTextDidChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .onChange(of: viewModel.searchText) { _ in
            viewModel.searchTextDidChange()
        }
    }

    // MARK: - Scope + index status

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 6) {
            Label("Entire directory", systemImage: "folder")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            if let status = viewModel.indexStatusText {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Search index status: \(status)")
            }

            Button {
                haptics.selectionChanged()
                viewModel.isSettingsPresented = true
            } label: {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("AI Search settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        Text("Try \"A Bug's Life 1080p\" or \"find the 1998 bugs movie\"")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityLabel("Example searches: A Bug's Life 1080p, find the 1998 bugs movie")
    }

    private func banner(_ message: String) -> some View {
        Label(message, systemImage: "wand.and.stars")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
            .accessibilityLabel(message)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        if viewModel.searchText.isEmpty {
            emptyPrompt
        } else if viewModel.results.isEmpty && viewModel.isSearching {
            Spacer()
            ProgressView()
            Spacer()
        } else if viewModel.results.isEmpty {
            noResults
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.results) { result in
                        DirectorySearchResultRow(
                            result: result,
                            onOpen: {
                                haptics.selectionChanged()
                                dismiss()
                                onOpenResult(result)
                            },
                            onDownload: { haptics.selectionChanged(); onDownload(result.asDirectoryItem) },
                            onPlay: { haptics.selectionChanged(); onPlay(result.asDirectoryItem) },
                            onShare: { haptics.selectionChanged(); onShare(result.asDirectoryItem) },
                            onCopyName: { haptics.selectionChanged(); onCopyName(result.asDirectoryItem) },
                            onBookmark: { haptics.selectionChanged(); onBookmark(result.asDirectoryItem) }
                        )
                        Divider()
                            .padding(.leading, 66)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityLabel("\(viewModel.results.count) search results")
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Type to search the entire directory")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No files match your search")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One ranked result row: filename, folder path, size/extension/type,
/// plus the existing Directory Mode actions.
public struct DirectorySearchResultRow: View {
    let result: DirectorySearchResult
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onPlay: () -> Void
    let onShare: () -> Void
    let onCopyName: () -> Void
    let onBookmark: () -> Void

    public init(
        result: DirectorySearchResult,
        onOpen: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onCopyName: @escaping () -> Void,
        onBookmark: @escaping () -> Void
    ) {
        self.result = result
        self.onOpen = onOpen
        self.onDownload = onDownload
        self.onPlay = onPlay
        self.onShare = onShare
        self.onCopyName = onCopyName
        self.onBookmark = onBookmark
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                DirectoryItemThumbnail(item: result.asDirectoryItem, size: 42)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.entry.filename)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1...2)

                    if !result.entry.relativePath.isEmpty {
                        Text(pathText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(metaText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Menu {
                    Button {
                        onOpen()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    if result.entry.type.isPlayableMedia {
                        Button {
                            onPlay()
                        } label: {
                            Label("Play", systemImage: "play.circle")
                        }
                    }
                    Button {
                        onDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    Button {
                        onShare()
                    } label: {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        onBookmark()
                    } label: {
                        Label("Bookmark", systemImage: "bookmark")
                    }
                    Button {
                        onCopyName()
                    } label: {
                        Label("Copy Name", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Actions for \(result.entry.filename)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(result.entry.filename), in \(pathText), \(metaText). Opens its folder"
        )
    }

    private var pathText: String {
        result.entry.relativePath.split(separator: "/").joined(separator: " › ")
    }

    private var metaText: String {
        let size = DirectoryItemFormatter.formattedFileSize(result.entry.sizeBytes)
        let ext = result.entry.fileExtension?.uppercased() ?? ""
        let type = result.entry.type.title
        let parts = [size, ext, type].filter { !$0.isEmpty && $0 != "Unknown size" }
        return parts.joined(separator: " • ")
    }
}

/// Minimal, focused AI Search configuration (from the AI Search UI itself —
/// no unrelated Settings tab sections touched).
public struct DirectoryAISearchSettingsView: View {
    @ObservedObject var viewModel: DirectoryAISearchViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(DirectorySearchSettings.isAIEnabledKey) private var aiEnabled: Bool = true
    @AppStorage(DirectorySearchSettings.useAIInterpretationKey) private var useInterpretation: Bool = true
    @AppStorage(DirectorySearchSettings.modelKey) private var model: String = "gemini-3.5-flash-lite"

    @State private var apiKey: String = ""

    private let keychain = DirectoryAIKeychainStore()

    public init(viewModel: DirectoryAISearchViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Enable AI Search", isOn: $aiEnabled)
                        .accessibilityLabel("Enable AI Search")
                    Toggle("Use AI query interpretation", isOn: $useInterpretation)
                        .accessibilityLabel("Use AI query interpretation")
                    SecureField("Gemini API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Gemini API key")
                    TextField("Gemini Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Gemini model name")
                } header: {
                    Text("AI Search")
                } footer: {
                    Text("The API key is stored securely in the iOS Keychain and never leaves this device. Without a key, AI interpretation is unavailable and local search is used.")
                }

                Section {
                    if let status = viewModel.indexStatusText {
                        Text(status)
                            .font(.subheadline)
                            .accessibilityLabel("Search index status: \(status)")
                    }
                    Button("Rebuild Search Index") { viewModel.refreshIndex() }
                        .accessibilityLabel("Rebuild search index")
                    Button("Clear Search Index", role: .destructive) { viewModel.clearIndex() }
                        .accessibilityLabel("Clear search index")
                } header: {
                    Text("Search Index")
                } footer: {
                    Text("The index caches the file listing of the current directory root so the server is not re-scanned on every search.")
                }
            }
            .navigationTitle("AI Search Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            apiKey = keychain.apiKey() ?? ""
        }
        .onChange(of: apiKey) { newValue in
            keychain.saveAPIKey(newValue)
        }
    }
}