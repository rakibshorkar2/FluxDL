import SwiftUI

public struct AddDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlString: String = ""
    @State private var customFilename: String = ""
    @State private var validationError: String?
    @State private var probeResult: DownloadProbeResult?
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?

    public let onStartDownload: (URL, String?) -> Void

    public init(onStartDownload: @escaping (URL, String?) -> Void) {
        self.onStartDownload = onStartDownload
    }

    private func handleStart() {
        var cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanURL.lowercased().hasPrefix("http://") && !cleanURL.lowercased().hasPrefix("https://") {
            cleanURL = "https://" + cleanURL
        }

        guard let url = URL(string: cleanURL), UIApplication.shared.canOpenURL(url) else {
            validationError = "Please enter a valid HTTP or HTTPS URL."
            return
        }

        let filename = customFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        onStartDownload(url, filename.isEmpty ? nil : filename)
        dismiss()
    }

    /// Debounced probe: learn about the URL without delaying the download.
    /// The probe cancels as soon as headers arrive (HEAD or a 1-byte ranged
    /// GET), so it never pulls the file body.
    private func probe(_ raw: String) {
        probeTask?.cancel()
        guard let url = URL(string: raw), UIApplication.shared.canOpenURL(url) else {
            probeResult = nil
            return
        }
        isProbing = true
        probeTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let result = await DownloadProbe(url: url).probe()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                probeResult = result
                isProbing = false
            }
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Download Link")) {
                    TextField("https://example.com/file.zip", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: urlString) { newValue in
                            probe(newValue)
                        }

                    TextField("Custom Filename (Optional)", text: $customFilename)
                        .textInputAutocapitalization(.never)
                }

                if isProbing {
                    Section("Checking URL") {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Inspecting link…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let probe = probeResult {
                    Section("Detected Download") {
                        if let filename = probe.filename, !filename.isEmpty {
                            InfoRowSmall(label: "Filename", value: filename)
                        }
                        if let length = probe.contentLength, length > 0 {
                            InfoRowSmall(label: "Size", value: ByteCountFormatter.string(fromByteCount: length, countStyle: .file))
                        }
                        InfoRowSmall(label: "Resume", value: probe.acceptsRanges ? "Supported" : "Not supported")
                        if let mime = probe.mimeType, !mime.isEmpty {
                            InfoRowSmall(label: "Type", value: mime)
                        }
                        if probe.expirationRisk != .unknown {
                            InfoRowSmall(label: "Link", value: probe.expirationRisk.rawValue, warn: true)
                        }
                        if probe.requiresAuthentication {
                            InfoRowSmall(label: "Auth", value: "Required", warn: true)
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

                Section {
                    Button(action: handleStart) {
                        HStack {
                            Spacer()
                            Label("Start Download", systemImage: "arrow.down.circle.fill")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("New Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onDisappear {
                probeTask?.cancel()
            }
        }
    }
}

/// Compact two-column row used inside the detected-download card.
private struct InfoRowSmall: View {
    let label: String
    let value: String
    var warn: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(warn ? Color.orange : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}
