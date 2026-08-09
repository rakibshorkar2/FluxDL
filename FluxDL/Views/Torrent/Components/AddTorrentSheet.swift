import SwiftUI
import UniformTypeIdentifiers

public struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var magnetInput: String = ""
    @State private var remoteURLInput: String = ""
    @State private var isFileImporterPresented = false
    @State private var isRemoteImporting = false
    @State private var validationError: String?

    public let onAddMagnet: (String) -> Bool
    public let onAddTorrentFile: (URL) -> Bool
    public let onAddRemoteTorrent: (URL) -> Void

    public init(
        onAddMagnet: @escaping (String) -> Bool,
        onAddTorrentFile: @escaping (URL) -> Bool,
        onAddRemoteTorrent: @escaping (URL) -> Void
    ) {
        self.onAddMagnet = onAddMagnet
        self.onAddTorrentFile = onAddTorrentFile
        self.onAddRemoteTorrent = onAddRemoteTorrent
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
                    if onAddTorrentFile(url) { dismiss() }
                case .failure(let error):
                    validationError = error.localizedDescription
                }
            }
        }
    }

    private func handleMagnet() {
        if onAddMagnet(magnetInput) { dismiss() }
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
        onAddRemoteTorrent(url)
        dismiss()
    }
}
