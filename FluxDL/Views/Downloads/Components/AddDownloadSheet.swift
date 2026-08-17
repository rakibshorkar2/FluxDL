import SwiftUI

public struct AddDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlString: String = ""
    @State private var customFilename: String = ""
    @State private var validationError: String?
    
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
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Download Link")) {
                    TextField("https://example.com/file.zip", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    TextField("Custom Filename (Optional)", text: $customFilename)
                        .textInputAutocapitalization(.never)
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
        }
    }
}
