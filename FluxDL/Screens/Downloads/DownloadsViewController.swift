//
//  DownloadsViewController.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Combine
import MvvmFoundation
import UIKit

class DownloadsViewController<VM: DownloadsViewModel>: BaseViewController<VM> {
    private lazy var collectionView: MvvmCollectionView = {
        let collectionView = MvvmCollectionView(frame: .zero, collectionViewLayout: .init())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        return collectionView
    }()

    private let addButton = UIBarButtonItem(title: %"downloads.add", image: .init(systemName: "plus"))

    override func viewDidLoad() {
        super.viewDidLoad()

        title = viewModel.title
        navigationItem.largeTitleDisplayMode = .always

        setupView()
        setupToolbar()
        binding()
        setupEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        smoothlyDeselectRows(in: collectionView)
    }

    override func viewLayoutMarginsDidChange() {
        super.viewLayoutMarginsDidChange()
        collectionView.contentInset = UIEdgeInsets(
            top: 0,
            left: view.layoutMargins.left,
            bottom: 0,
            right: view.layoutMargins.right
        )
    }
}

private extension DownloadsViewController {
    func setupView() {
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    func setupToolbar() {
        addButton.primaryAction = .init(title: %"downloads.add", image: .init(systemName: "plus")) { [unowned self] _ in
            present(makeAddDownloadAlert(), animated: true)
        }

        navigationItem.trailingItemGroups.append(.fixedGroup(items: [addButton]))
    }

    func setupEmptyState() {
        guard #available(iOS 17.0, *) else { return }

        viewModel.$isEmpty.uiSink { [unowned self] isEmpty in
            guard isEmpty else {
                contentUnavailableConfiguration = nil
                return
            }

            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = .init(systemName: "square.and.arrow.down")
            configuration.text = %"downloads.empty.title"
            configuration.secondaryText = %"downloads.empty.subtitle"
            contentUnavailableConfiguration = configuration
        }
    }
}

private extension DownloadsViewController {
    func binding() {
        disposeBag.bind {
            viewModel.$sections.uiSink { [unowned self] sections in
                collectionView.sections.send(sections)
            }
        }

        collection.contextMenuConfigurationForItemsAt = { [unowned self] indexPaths, _ in
            guard let indexPath = indexPaths.first,
                  let cellViewModel = viewModel.sections[indexPath.section].items[indexPath.item] as? DownloadItemViewModel
            else { return nil }

            let share = UIAction(
                title: %"common.share",
                image: .init(systemName: "square.and.arrow.up"),
                attributes: cellViewModel.canShare ? [] : .hidden
            ) { [weak self] _ in
                guard let self, let fileURL = cellViewModel.fileURL else { return }
                let activityViewController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                self.present(activityViewController, animated: true)
            }

            let resume = UIAction(
                title: %"details.start",
                image: .init(systemName: "play.fill"),
                attributes: cellViewModel.canResume ? [] : .hidden
            ) { _ in
                cellViewModel.resumeAction?()
            }

            let pause = UIAction(
                title: %"details.pause",
                image: .init(systemName: "pause.fill"),
                attributes: cellViewModel.canPause ? [] : .hidden
            ) { _ in
                cellViewModel.pauseAction?()
            }

            let delete = UIAction(
                title: %"common.delete",
                image: .init(systemName: "trash.fill"),
                attributes: .destructive
            ) { _ in
                cellViewModel.deleteAction?()
            }

            return UIContextMenuConfiguration(actionProvider: { _ in
                UIMenu(title: cellViewModel.filename, children: [
                    share,
                    resume,
                    pause,
                    UIMenu(options: .displayInline, children: [delete])
                ])
            })
        }
    }

    func makeAddDownloadAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: %"downloads.add.title",
            message: %"downloads.add.message",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = %"downloads.add.placeholder"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }

        alert.addAction(.init(title: %"common.cancel", style: .cancel))

        alert.addAction(.init(title: %"common.ok", style: .default) { [unowned self] _ in
            var text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty, let pasted = UIPasteboard.general.string {
                text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased()),
                  viewModel.addDownload(from: url) != nil
            else {
                let errorAlert = UIAlertController(
                    title: %"common.error",
                    message: %"downloads.add.error",
                    preferredStyle: .alert
                )
                errorAlert.addAction(.init(title: %"common.close", style: .cancel), isPrimary: true)
                present(errorAlert, animated: true)
                return
            }
        }, isPrimary: true)

        return alert
    }
}