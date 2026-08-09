import SwiftUI

// MARK: - UpdateURLSheet

public struct UpdateURLSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let task: DownloadTaskModel
    public let onUpdate: (URL) -> Void

    @State private var urlString: String
    @State private var validationResult: DownloadURLValidationResult?
    @State private var isValidating = false

    public init(task: DownloadTaskModel, onUpdate: @escaping (URL) -> Void) {
        self.task     = task
        self.onUpdate = onUpdate
        // Pre-populate with existing URL
        _urlString = State(initialValue: task.url.absoluteString)
    }

    private var validURL: URL? {
        if case .valid(let url) = validationResult { return url }
        return nil
    }

    private var errorMessage: String? {
        if case .invalid(let msg) = validationResult { return msg }
        return nil
    }

    public var body: some View {
        NavigationStack {
            Form {
                // ── Current state ────────────────────────────────────────
                Section("Current Download") {
                    LabeledContent("Filename", value: task.filename)
                    LabeledContent("Status", value: task.status.rawValue)
                    if let originalURL = task.url.host {
                        LabeledContent("Original Host", value: originalURL)
                    }
                }

                // ── New URL ──────────────────────────────────────────────
                Section {
                    TextField("https://example.com/file.zip", text: $urlString, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3)
                        .onChange(of: urlString) { _, _ in
                            // Clear previous result on change
                            validationResult = nil
                        }
                } header: {
                    Text("New URL")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if validURL != nil {
                            Label("URL is valid and ready to use.", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        Text("The original filename, destination, creation date, and metadata will be preserved. Progress cannot be resumed with a different URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Preservation note ────────────────────────────────────
                Section("What's Preserved") {
                    PreservedRow(icon: "doc.text",         label: "Original Filename")
                    PreservedRow(icon: "folder",            label: "Destination Folder")
                    PreservedRow(icon: "calendar",          label: "Creation Date")
                    PreservedRow(icon: "list.bullet",       label: "Mirror List")
                    PreservedRow(icon: "tag",               label: "Tags & Category")
                    PreservedRow(icon: "arrow.clockwise",   label: "Retry History")
                }

                // ── Action ───────────────────────────────────────────────
                Section {
                    Button {
                        handleValidateAndReconnect()
                    } label: {
                        HStack {
                            Spacer()
                            if isValidating {
                                ProgressView().scaleEffect(0.8)
                                Text("Validating…")
                                    .fontWeight(.semibold)
                            } else if validURL != nil {
                                Label("Reconnect Download", systemImage: "arrow.down.circle.fill")
                                    .fontWeight(.bold)
                            } else {
                                Label("Validate & Reconnect", systemImage: "checkmark.circle")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
                    .tint(validURL != nil ? .green : .accentColor)
                }
            }
            .navigationTitle("Update Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Logic

    private func handleValidateAndReconnect() {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // If already validated, proceed directly
        if let url = validURL {
            onUpdate(url)
            dismiss()
            return
        }

        isValidating = true

        // Validate synchronously (URL(string:) is cheap)
        var adjusted = clean
        if !adjusted.lowercased().hasPrefix("http://") && !adjusted.lowercased().hasPrefix("https://") {
            adjusted = "https://" + adjusted
        }

        if let url = URL(string: adjusted), UIApplication.shared.canOpenURL(url) {
            validationResult = .valid(url)
        } else {
            validationResult = .invalid("Please enter a valid HTTP or HTTPS URL.")
        }

        isValidating = false

        // If valid, reconnect on the next tap
        if case .valid(let url) = validationResult {
            onUpdate(url)
            dismiss()
        }
    }
}

// MARK: - PreservedRow

private struct PreservedRow: View {
    let icon: String
    let label: String

    var body: some View {
        Label {
            Text(label)
                .font(.subheadline)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.green)
        }
    }
}
