//
//  DownloadsViewModel.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Combine
import Foundation
import MvvmFoundation
import UIKit

class DownloadsViewModel: BaseViewModel {
    @Published private(set) var sections: [MvvmCollectionSectionModel] = []
    @Published private(set) var isEmpty = true
    @Published var title = ""

    private let engine = DownloadEngine.shared
    private var cellCache: [UUID: DownloadItemViewModel] = [:]

    required init() {
        super.init()
        title = "Downloads".localized

        engine.$items
            .map { [unowned self] items in
                self.makeSections(from: items)
            }
            .assign(to: &$sections)

        engine.$items
            .map(\.isEmpty)
            .assign(to: &$isEmpty)
    }

    @discardableResult
    func addDownload(from url: URL) -> DownloadItem? {
        engine.addDownload(from: url)
    }

    // MARK: - Item operations

    func refresh(_ id: UUID) {
        engine.refresh(id)
    }

    func updateLink(_ id: UUID) {
        guard let item = engine.items.first(where: { $0.id == id }) else { return }

        textInput(
            title: %"downloads.update_link.title",
            message: %"downloads.update_link.message",
            placeholder: "https://example.com/file.zip",
            defaultValue: item.url,
            type: .URL,
            accept: %"common.ok",
            result: { [weak self] newURL in
                guard let self, let newURL else { return }
                guard let url = URL(string: newURL),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme)
                else {
                    alert(title: %"common.error", message: %"downloads.add.error", actions: [
                        .init(title: %"common.close", style: .cancel, isPrimary: true)
                    ])
                    return
                }
                self.engine.updateLink(id, to: url)
            }
        )
    }

    func delete(_ id: UUID) {
        engine.remove(id, deleteFile: true)
    }

    func removeKeepingFile(_ id: UUID) {
        engine.remove(id, deleteFile: false)
    }

    func confirmDelete(_ id: UUID) {
        alert(title: %"downloads.delete.confirm.title", message: %"downloads.delete.confirm.message", actions: [
            .init(title: %"common.cancel", style: .cancel, isPrimary: true),
            .init(title: %"common.delete", style: .destructive, action: { [weak self] in
                self?.delete(id)
            })
        ])
    }

    // MARK: - Batch operations

    func pauseAll(at indexPaths: [IndexPath]) {
        items(at: indexPaths).forEach { engine.pause($0.id) }
    }

    func resumeAll(at indexPaths: [IndexPath]) {
        items(at: indexPaths).forEach { engine.resume($0.id) }
    }

    func confirmDeleteAll(at indexPaths: [IndexPath]) {
        let count = indexPaths.count
        alert(title: %"downloads.delete.batch.title", message: String(format: %"downloads.delete.batch.message", count), actions: [
            .init(title: %"common.cancel", style: .cancel, isPrimary: true),
            .init(title: %"common.delete", style: .destructive, action: { [weak self] in
                guard let self else { return }
                self.items(at: indexPaths).forEach { self.engine.remove($0.id, deleteFile: true) }
            })
        ])
    }

    private func items(at indexPaths: [IndexPath]) -> [DownloadItemViewModel] {
        indexPaths.compactMap { indexPath in
            guard sections.indices.contains(indexPath.section),
                  sections[indexPath.section].items.indices.contains(indexPath.item)
            else { return nil }

            return sections[indexPath.section].items[indexPath.item] as? DownloadItemViewModel
        }
    }

    private func makeSections(from items: [DownloadItem]) -> [MvvmCollectionSectionModel] {
        let sorted = items.sorted { $0.createdAt > $1.createdAt }
        let cellViewModels = sorted.map { item in
            cellCache[item.id] ?? {
                let vm = DownloadItemViewModel(with: item)
                cellCache[item.id] = vm
                return vm
            }()
        }

        guard !cellViewModels.isEmpty
        else { return [] }

        return [
            MvvmCollectionSectionModel(id: "downloads", style: .insetGrouped, items: cellViewModels)
        ]
    }
}