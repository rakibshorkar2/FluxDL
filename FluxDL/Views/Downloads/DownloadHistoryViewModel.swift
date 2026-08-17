import Foundation
import Combine
import SwiftUI
import UIKit

// MARK: - DownloadHistoryViewModel

@MainActor
public final class DownloadHistoryViewModel: ObservableObject {

    /// Row id currently showing the transient "Copied" confirmation.
    @Published public var copiedEntryID: UUID?
    /// Entry awaiting explicit delete confirmation.
    @Published public var pendingDelete: DownloadHistoryEntry?

    public let onRetry: (DownloadHistoryEntry) -> Void

    private let historyManager: DownloadHistoryManager
    private let clipboardService: ClipboardServiceProtocol
    private let hapticService: HapticServiceProtocol
    private let fileManagerService: FileManagementServiceProtocol
    private var copyResetTask: Task<Void, Never>?

    public init(
        historyManager:     DownloadHistoryManager         = ServiceContainer.shared.downloadHistoryManager,
        clipboardService:   ClipboardServiceProtocol       = ServiceContainer.shared.clipboardService,
        hapticService:      HapticServiceProtocol          = ServiceContainer.shared.hapticService,
        fileManagerService: FileManagementServiceProtocol  = ServiceContainer.shared.fileManagementService,
        onRetry:            @escaping (DownloadHistoryEntry) -> Void
    ) {
        self.historyManager     = historyManager
        self.clipboardService   = clipboardService
        self.hapticService      = hapticService
        self.fileManagerService = fileManagerService
        self.onRetry            = onRetry
    }

    public var entries: [DownloadHistoryEntry] {
        historyManager.entries
    }

    // MARK: ── Actions ─────────────────────────────────────────────────────

    /// Copies the ORIGINAL download link to the pasteboard.
    /// The clipboard service is told to ignore this string so the detection
    /// banner never re-appears as a side effect (no feedback loop, and
    /// copying never creates a download).
    public func copyURL(_ entry: DownloadHistoryEntry) {
        UIPasteboard.general.string = entry.originalURL.absoluteString
        clipboardService.markPasteboardAsChecked(entry.originalURL.absoluteString)
        hapticService.notificationOccurred(.success)

        withAnimation(AppTheme.quickSpring) {
            copiedEntryID = entry.id
        }
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedEntryID = nil
        }
    }

    /// Explicit delete of a history record only — never touches the active
    /// Downloads list.
    public func remove(_ entry: DownloadHistoryEntry) {
        historyManager.remove(id: entry.id)
        if copiedEntryID == entry.id { copiedEntryID = nil }
        hapticService.impactOccurred(.light)
    }

    /// Explicit delete of the entire history.
    public func clearAll() {
        guard !entries.isEmpty else { return }
        historyManager.clearAll()
        copiedEntryID = nil
        hapticService.notificationOccurred(.success)
    }

    /// Start/retry the download using the saved original URL.
    public func retry(_ entry: DownloadHistoryEntry) {
        hapticService.selectionChanged()
        onRetry(entry)
    }

    /// Shares the saved original URL.
    public func shareURL(_ entry: DownloadHistoryEntry) {
        fileManagerService.shareFile(url: entry.originalURL, from: nil)
        hapticService.impactOccurred(.light)
    }
}
