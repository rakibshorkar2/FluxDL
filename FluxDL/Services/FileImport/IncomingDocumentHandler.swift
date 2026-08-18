import Foundation
import Combine
import LibTorrent

/// Routes documents opened into FluxDL (share sheet / Files "Open with",
/// via the `CFBundleDocumentTypes` declarations) to the existing import
/// flows:
///
///     YAML   → ProxyYAMLImportView preview (existing UI)
///     .torrent → TorrentService (existing engine)
///
/// Every incoming document is first copied into the app's temporary storage
/// so parsing never depends on a virtualized/external provider URL
/// (LiveContainer). Only `.yaml`, `.yml` and `.torrent` files are handled.
@MainActor
public final class IncomingDocumentHandler: ObservableObject {
    public static let shared = IncomingDocumentHandler()

    /// Reuses the real Proxy flow's view model so incoming YAML documents
    /// present the same review-and-import screen.
    public let proxyViewModel = ProxyViewModel()

    @Published public var pendingYAMLResult: ProxyYAMLImportResult?
    @Published public var isYAMLResultsPresented = false
    @Published public var alertMessage: String?
    @Published public var isAlertPresented = false

    private init() {}

    // MARK: - Entry point

    public func handle(url: URL) {
        if ImportedDocumentReader.isYAMLDocument(url) {
            importYAML(at: url)
        } else if ImportedDocumentReader.isTorrentDocument(url) {
            importTorrent(at: url)
        } else {
            showAlert(ImportedDocumentError.invalidDocument.userMessage)
        }
    }

    public func clearYAMLImport() {
        pendingYAMLResult = nil
        isYAMLResultsPresented = false
    }

    // MARK: - YAML

    private func importYAML(at url: URL) {
        switch ImportedDocumentReader.readableCopy(of: url, preferredExtension: "yaml") {
        case .failure(let error):
            showAlert(error.userMessage)
        case .success(let localURL):
            defer { ImportedDocumentReader.removeTemporaryCopy(at: localURL) }
            switch ImportedDocumentReader.readText(from: localURL) {
            case .failure(let error):
                showAlert(error.userMessage)
            case .success(let text):
                // The existing parser stays authoritative.
                guard let result = proxyViewModel.service.parseYAML(text) else {
                    showAlert("The selected file could not be parsed as YAML.")
                    return
                }
                pendingYAMLResult = result
                isYAMLResultsPresented = true
            }
        }
    }

    // MARK: - Torrent

    private func importTorrent(at url: URL) {
        switch ImportedDocumentReader.readableCopy(of: url, preferredExtension: "torrent") {
        case .failure(let error):
            showAlert(error.userMessage)
        case .success(let localURL):
            defer { ImportedDocumentReader.removeTemporaryCopy(at: localURL) }
            // TorrentFile is the authoritative validator; the engine never
            // sees a document-provider URL.
            guard TorrentFile(with: localURL) != nil else {
                showAlert("Invalid or unsupported .torrent file.")
                return
            }
            let service = TorrentService.shared
            if !service.isSessionActive {
                service.startSession()
            }
            switch service.addTorrentFile(at: localURL) {
            case .success:
                showAlert("Torrent added.")
            case .failure(let error):
                showAlert(error.message)
            }
        }
    }

    // MARK: - Alerts

    private func showAlert(_ message: String) {
        alertMessage = message
        isAlertPresented = true
    }
}