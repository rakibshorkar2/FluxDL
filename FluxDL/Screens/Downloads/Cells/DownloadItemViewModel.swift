//
//  DownloadItemViewModel.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Combine
import Foundation
import MvvmFoundation

class DownloadItemViewModel: BaseViewModelWith<DownloadItem>, MvvmSelectableProtocol, ObservableObject, Identifiable {
    var item: DownloadItem!
    var selectAction: (() -> Void)?

    var id: UUID { item.id }

    @Published var filename = ""
    @Published var detailText = ""
    @Published var statusText = ""
    @Published var progress = 0.0
    @Published var iconName = ""

    var canPause: Bool { item.status == .downloading }
    var canResume: Bool { item.status == .paused || item.status == .failed || item.status == .queued }
    var canShare: Bool { item.status == .completed && item.downloadedFilename != nil }

    var fileURL: URL? {
        guard canShare, let filename = item.downloadedFilename else { return nil }
        return DownloadEngine.downloadsFolderURL.appendingPathComponent(filename)
    }

    var pauseAction: (() -> Void)?
    var resumeAction: (() -> Void)?
    var deleteAction: (() -> Void)?
    var removeKeepFileAction: (() -> Void)?
    var shareAction: (() -> Void)?

    var trailingIconName: String {
        switch item.status {
        case .downloading: return "pause.circle.fill"
        case .queued, .paused, .failed, .cancelled: return "play.circle.fill"
        case .completed: return "square.and.arrow.up"
        }
    }

    var trailingAction: (() -> Void)? {
        switch item.status {
        case .downloading: return pauseAction
        case .queued, .paused, .failed, .cancelled: return resumeAction
        case .completed: return shareAction
        }
    }

    override func prepare(with model: DownloadItem) {
        item = model
        updateUI()

        pauseAction = { [weak self] in
            self?.pause()
        }
        resumeAction = { [weak self] in
            self?.resume()
        }
        deleteAction = { [weak self] in
            self?.remove()
        }
        removeKeepFileAction = { [weak self] in
            self?.removeKeepingFile()
        }

        disposeBag.bind {
            DownloadEngine.shared.$items
                .compactMap { items in items.first { $0.id == model.id } }
                .removeDuplicates { $0.id == $1.id && $0.status == $1.status && $0.bytesReceived == $1.bytesReceived && $0.totalBytes == $1.totalBytes && $0.speed == $1.speed && $0.filename == $1.filename && $0.errorMessage == $1.errorMessage }
                .sink { [weak self] updated in
                    self?.item = updated
                    self?.updateUI()
                }
        }
    }

    override func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private func pause() {
        DownloadEngine.shared.pause(item.id)
    }

    private func resume() {
        DownloadEngine.shared.resume(item.id)
    }

    private func remove() {
        DownloadEngine.shared.remove(item.id, deleteFile: true)
    }

    private func removeKeepingFile() {
        DownloadEngine.shared.remove(item.id, deleteFile: false)
    }
}

private extension DownloadItemViewModel {
    func updateUI() {
        filename = item.filename
        progress = item.progress

        switch item.status {
        case .queued:
            detailText = ""
            statusText = %"downloads.state.queued"
            iconName = "clock"
        case .downloading:
            detailText = "\(UInt64(max(0, item.bytesReceived)).bitrateToHumanReadable) / \(UInt64(max(0, item.totalBytes)).bitrateToHumanReadable) (\(String(format: "%.1f%%", item.progress * 100)))"
            statusText = "\(UInt64(item.speed).bitrateToHumanReadable)/s"
            iconName = "arrow.down.circle.fill"
        case .paused:
            detailText = "\(UInt64(item.bytesReceived).bitrateToHumanReadable)"
            statusText = %"downloads.state.paused"
            iconName = "pause.circle"
        case .completed:
            let size = item.bytesReceived > 0 ? UInt64(item.bytesReceived).bitrateToHumanReadable : UInt64(item.totalBytes).bitrateToHumanReadable
            detailText = size
            statusText = %"downloads.state.completed"
            iconName = "checkmark.circle.fill"
        case .failed:
            detailText = item.errorMessage ?? ""
            statusText = %"downloads.state.failed"
            iconName = "xmark.octagon.fill"
        case .cancelled:
            detailText = item.errorMessage ?? ""
            statusText = %"downloads.state.cancelled"
            iconName = "xmark.circle"
        }
    }
}