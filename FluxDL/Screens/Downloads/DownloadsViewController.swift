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
        collectionView.allowsMultipleSelectionDuringEditing = true
        return collectionView
    }()

    private let addButton = UIBarButtonItem(title: %"downloads.add", image: .init(systemName: "plus"))

    private let resumeAllButton = UIBarButtonItem(title: %"downloads.batch.resume", image: .init(systemName: "play.fill"))
    private let pauseAllButton = UIBarButtonItem(title: %"downloads.batch.pause", image: .init(systemName: "pause.fill"))
    private let deleteAllButton = UIBarButtonItem(title: %"common.delete", image: .init(systemName: "trash"))

    override func viewDidLoad() {
        super.viewDidLoad()

        title = viewModel.title
        navigationItem.largeTitleDisplayMode = .always

        setupView()
        setupToolbar()
        binding()
        setupEmptyState()

        navigationItem.leadingItemGroups.append(.fixedGroup(items: [editButtonItem]))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        smoothlyDeselectRows(in: collectionView)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isEditing {
            setEditing(false, animated: false)
        }
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

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        toolbarItems = getToolBarItems
        navigationController?.setToolbarHidden(isToolbarItemsHidden, animated: true)

        // On iOS 26 the tab bar floats above the content as a Liquid Glass layer,
        // overlapping the navigation toolbar below it. Hide the tab bar while
        // editing so the action toolbar is fully visible.
        if #available(iOS 18.0, *) {
            tabBarController?.setTabBarHidden(editing, animated: true)
        }
    }
}

private extension DownloadsViewController {
    var getToolBarItems: [UIBarButtonItem] {
        guard isEditing else { return [] }
        return [
            resumeAllButton,
            pauseAllButton,
            .flexibleSpace(),
            deleteAllButton
        ]
    }

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

        resumeAllButton.primaryAction = .init(title: %"downloads.batch.resume", image: .init(systemName: "play.fill")) { [unowned self] _ in
            viewModel.resumeAll(at: collectionView.indexPathsForSelectedItems ?? [])
            setEditing(false, animated: true)
        }

        pauseAllButton.primaryAction = .init(title: %"downloads.batch.pause", image: .init(systemName: "pause.fill")) { [unowned self] _ in
            viewModel.pauseAll(at: collectionView.indexPathsForSelectedItems ?? [])
            setEditing(false, animated: true)
        }

        deleteAllButton.primaryAction = .init(title: %"common.delete", image: .init(systemName: "trash")) { [unowned self] _ in
            let indexPaths = collectionView.indexPathsForSelectedItems ?? []
            guard !indexPaths.isEmpty else { return }
            viewModel.confirmDeleteAll(at: indexPaths)
        }
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

                for section in sections {
                    for item in section.items {
                        guard let vm = item as? DownloadItemViewModel,
                              vm.shareAction == nil
                        else { continue }

                        vm.shareAction = { [weak self] in
                            guard let self, let fileURL = vm.fileURL else { return }
                            let activityViewController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                            self.present(activityViewController, animated: true)
                        }
                    }
                }
            }

            collectionView.$selectedIndexPaths.uiSink { [unowned self] indexPaths in
                let isEmpty = indexPaths.isEmpty
                resumeAllButton.isEnabled = !isEmpty
                pauseAllButton.isEnabled = !isEmpty
                deleteAllButton.isEnabled = !isEmpty
            }
        }

        collectionView.contextMenuConfigurationForItemsAt = { [unowned self] indexPaths, _ in
            guard let indexPath = indexPaths.first,
                  let cellViewModel = viewModel.sections[indexPath.section].items[indexPath.item] as? DownloadItemViewModel
            else { return nil }

            let share = UIAction(
                title: %"common.share",
                image: .init(systemName: "square.and.arrow.up"),
                attributes: cellViewModel.canShare ? [] : .hidden
            ) { _ in
                cellViewModel.shareAction?()
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

            let refresh = UIAction(
                title: %"downloads.action.refresh",
                image: .init(systemName: "arrow.clockwise"),
                attributes: cellViewModel.canResume ? [] : .hidden
            ) { [unowned self] _ in
                viewModel.refresh(cellViewModel.id)
            }

            let updateLink = UIAction(
                title: %"downloads.action.update_link",
                image: .init(systemName: "link")
            ) { [unowned self] _ in
                viewModel.updateLink(cellViewModel.id)
            }

            let removeKeepingFile = UIAction(
                title: %"downloads.action.remove_keep",
                image: .init(systemName: "folder")
            ) { [unowned self] _ in
                viewModel.removeKeepingFile(cellViewModel.id)
            }

            let delete = UIAction(
                title: %"common.delete",
                image: UIImage(systemName: "trash.fill"),
                attributes: .destructive
            ) { [unowned self] _ in
                viewModel.confirmDelete(cellViewModel.id)
            }

            return UIContextMenuConfiguration(actionProvider: { _ in
                UIMenu(title: cellViewModel.filename, children: [
                    share,
                    UIMenu(options: .displayInline, children: [
                        resume,
                        pause,
                        refresh
                    ]),
                    UIMenu(options: .displayInline, children: [
                        updateLink,
                        removeKeepingFile
                    ]),
                    UIMenu(options: .displayInline, children: [
                        delete
                    ])
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
