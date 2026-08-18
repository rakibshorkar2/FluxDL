import SwiftUI
import UniformTypeIdentifiers

/// Shared UIKit document-picker wrapper used by the YAML and `.torrent`
/// import flows.
///
/// The picker always requests a copy (`asCopy: true`) so the callback
/// receives an app-readable local copy instead of a security-scoped
/// document-provider URL. SwiftUI's `.fileImporter` and non-copy pickers can
/// be unreliable when the app runs inside a virtualized environment
/// (LiveContainer), where externally backed URLs may not stay readable.
public struct DocumentFilePickerView: UIViewControllerRepresentable {
    public let contentTypes: [UTType]
    public let allowsMultipleSelection: Bool
    public let onPicked: (URL) -> Void
    public let onCancel: () -> Void

    public init(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        onPicked: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.contentTypes = contentTypes
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onPicked = onPicked
        self.onCancel = onCancel
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentFilePickerView

        fileprivate init(_ parent: DocumentFilePickerView) {
            self.parent = parent
        }

        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPicked(url)
        }

        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}