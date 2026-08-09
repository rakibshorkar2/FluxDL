import SwiftUI
import UniformTypeIdentifiers

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

    public let onAddMagnet: (String, AddTorrentOptions) -> Bool
    public let onAddTorrentFile: (URL, AddTorrentOptions) -> Bool
    public let onAddRemoteTorrent: (URL, AddTorrentOptions) -> Void

    public init(
        onAddMagnet: @escaping (String, AddTorrentOptions) -> Bool,
        onAddTorrentFile: @escaping (URL, AddTorrentOptions) -> Bool,
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

                Section("Download Options") {
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
                } footer: {
                    Text("Options apply to torrents added from this screen. You can change them later from the torrent details.")
                }

                if let error = validationError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle("Add Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if onAddTorrentFile(url, options) { dismiss() }
                case .failure(let error):
                    validationError = error.localizedDescription
                }
            }
        }
    }

    private func handleMagnet() {
        if onAddMagnet(magnetInput, options) { dismiss() }
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
