//
//  DownloadsViewModel.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Combine
import Foundation
import MvvmFoundation

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