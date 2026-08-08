//
//  DownloadsSettingsViewModel.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Combine
import MvvmFoundation
import UIKit

class DownloadsSettingsViewModel: BasePreferencesViewModel {
    @Injected private var preferences: DownloadsPreferences

    required init() {
        super.init()
        binding()
        reload()
    }

    private func binding() {
        disposeBag.bind {
            preferences.$allowsCellular
                .dropFirst()
                .sink { [unowned self] _ in
                    DownloadEngine.shared.applyCellularPreference()
                }
        }
    }

    func reload() {
        title.send(%"downloads.settings.title")

        var sections: [MvvmCollectionSectionModel] = []
        defer { self.sections.send(sections) }

        sections.append(.init(id: "general", header: %"downloads.settings.general") {
            PRButtonViewModel(with: .init(title: %"downloads.settings.concurrent", value: preferences.$maxActiveDownloads.map { "\($0)" }.eraseToAnyPublisher(), accessories: [
                .popUpMenu(
                    .init(title: %"downloads.settings.concurrent.action", children: [
                        uiAction(for: 1),
                        uiAction(for: 2),
                        uiAction(for: 3),
                        uiAction(for: 5),
                    ]), options: .init(tintColor: .tintColor)
                ),
            ]))
            PRSwitchViewModel(with: .init(title: %"downloads.settings.cellular", value: preferences.$allowsCellular.binding))
            PRSwitchViewModel(with: .init(title: %"downloads.settings.autoretry", value: preferences.$autoRetryFailed.binding))
        })

        sections.append(.init(id: "storage", header: %"downloads.settings.storage") {
            PRButtonViewModel(with: .init(title: %"downloads.settings.storage.path", value: Just(DownloadEngine.downloadsFolderURL.path).eraseToAnyPublisher(), selectAction: nil))
            PRButtonViewModel(with: .init(title: %"downloads.settings.clear_completed") { [unowned self] in
                dismissSelection.send()
                alert(title: %"downloads.settings.clear_completed.confirm_title", message: %"downloads.settings.clear_completed.confirm_message", actions: [
                    .init(title: %"common.cancel", style: .cancel),
                    .init(title: %"common.delete", style: .destructive, isPrimary: true, action: {
                        DownloadEngine.shared.clearCompleted()
                    })
                ])
            })
        })
    }

    func uiAction(for count: Int) -> UIAction {
        UIAction(title: "\(count)", state: preferences.maxActiveDownloads == count ? .on : .off) { [preferences] _ in
            preferences.maxActiveDownloads = count
        }
    }
}
