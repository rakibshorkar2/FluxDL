import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The `.torrent` file type. Declared in Info.plist as an imported UTI so the
/// system document picker recognises and allows selecting BitTorrent files.
extension UTType {
    static let torrentMetadata = UTType(filenameExtension: "torrent") ?? .data
}

public struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var magnetInput: String = ""
    @State private var remoteURLInput: String = ""
    @State private var isFileImporterPresented = false
    @State private var isRemoteImporting = false
    @State private var validationError: String?

    // ── Per-torrent options applied on add ────────────────────────────────
    @State private var stopSeeding = false
    @State private var sequentialDownload = false
    @State private var firstLastPiecePriority = false
    @State private var downloadLimit = TorrentSpeedPreset.unlimited
    @State private var uploadLimit = TorrentSpeedPreset.unlimited

    public let onAddMagnet: (String, AddTorrentOptions) -> String?
    public let onAddTorrentFile: (URL, AddTorrentOptions) -> String?
    public let onAddRemoteTorrent: (URL, AddTorrentOptions) -> Void

    public init(
        onAddMagnet: @escaping (String, AddTorrentOptions) -> String?,
        onAddTorrentFile: @escaping (URL, AddTorrentOptions) -> String?,
        onAddRemoteTorrent: @escaping (URL, AddTorrentOptions) -> Void
    ) {
        self.onAddMagnet = onAddMagnet
        self.onAddTorrentFile = onAddTorrentFile
        self.onAddRemoteTorrent = onAddRemoteTorrent
    }

    private var options: AddTorrentOptions {
        var options = AddTorrentOptions()
        options.stopSeeding = stopSeeding
        options.sequentialDownload = sequentialDownload
        options.firstLastPiecePriority = firstLastPiecePriority
        options.downloadLimit = Int64(downloadLimit.rawValue)
        options.uploadLimit = Int64(uploadLimit.rawValue)
        return options
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Magnet Link")) {
                    TextField("magnet:?xt=urn:btih:...", text: $magnetInput, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(action: handleMagnet) {
                        HStack {
                            Spacer()
                            Label("Add Magnet", systemImage: "link")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                    .disabled(magnetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(header: Text("Torrent File")) {
                    Button(action: { isFileImporterPresented = true }) {
                        HStack {
                            Spacer()
                            Label("Choose .torrent File", systemImage: "doc.badge.plus")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                }

                Section(header: Text("Remote .torrent URL")) {
                    TextField("https://example.com/file.torrent", text: $remoteURLInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(action: handleRemoteURL) {
                        HStack {
                            Spacer()
                            if isRemoteImporting {
                                ProgressView()
                            } else {
                                Label("Download & Add", systemImage: "arrow.down.circle.fill")
                                    .fontWeight(.bold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRemoteImporting)
                }

                Section(header: Text("Download Options"), footer: Text("Options apply to torrents added from this screen. You can change them later from the torrent details.")) {
                    Toggle("Stop seeding when finished", isOn: $stopSeeding)

                    Toggle("Sequential download", isOn: $sequentialDownload)

                    Toggle("Download first & last pieces first", isOn: $firstLastPiecePriority)

                    Picker("Download Limit", selection: $downloadLimit) {
                        ForEach(TorrentSpeedPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    Picker("Upload Limit", selection: $uploadLimit) {
                        ForEach(TorrentSpeedPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                }

                if let error = validationError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .toggleStyle(AppToggleStyle())
            .navigationTitle("Add Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $isFileImporterPresented) {
                // UIKit document picker requesting a copy (asCopy: true): the
                // selected .torrent must be an app-local file so LibTorrent
                // never reads an externally backed provider URL (reliable
                // under LiveContainer too). Generic .data stays allowed because
                // some document providers misreport the torrent UTI.
                DocumentFilePickerView(
                    contentTypes: [.torrentMetadata, .data],
                    onPicked: { url in
                        isFileImporterPresented = false
                        handlePickedTorrent(url)
                    },
                    onCancel: { isFileImporterPresented = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    private func handleMagnet() {
        if let error = onAddMagnet(magnetInput, options) {
            validationError = error
        } else {
            dismiss()
        }
    }

    /// Handles a `.torrent` picked through `DocumentFilePickerView`. The URL
    /// is a system-provided copy; a defensive local copy is taken when the
    /// URL is not app-local so the engine only ever reads a sandbox file.
    private func handlePickedTorrent(_ url: URL) {
        switch ImportedDocumentReader.readableCopy(of: url, preferredExtension: "torrent") {
        case .failure(let error):
            validationError = error.userMessage
        case .success(let localURL):
            // The engine parses the file synchronously (TorrentFile) and keeps
            // its own copy of the metadata; the temporary source can be
            // released immediately after the add returns.
            defer { ImportedDocumentReader.removeTemporaryCopy(at: localURL) }
            if let error = onAddTorrentFile(localURL, options) {
                validationError = error
            } else {
                dismiss()
            }
        }
    }

    private func handleRemoteURL() {
        var clean = remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.lowercased().hasPrefix("http://") && !clean.lowercased().hasPrefix("https://") {
            clean = "https://" + clean
        }
        guard let url = URL(string: clean) else {
            validationError = "Please enter a valid URL."
            return
        }
        isRemoteImporting = true
        validationError = nil
        onAddRemoteTorrent(url, options)
        dismiss()
    }
}
