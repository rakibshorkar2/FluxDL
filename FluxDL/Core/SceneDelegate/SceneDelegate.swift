//
//  SceneDelegate.swift
//  iTorrent
//
//  Created by Daniil Vinogradov on 29/10/2023.
//

import LibTorrent
import MvvmFoundation
import UIKit
import AVKit

class SceneDelegate: MvvmSceneDelegate {
    override func initialSetup() {
        UIView.enableUIColorsToLayer()
    }

    override func register(in container: Container) {
        registerAVPlayer(in: container)
        container.register(type: UINavigationController.self, factory: BaseNavigationController.init)
        container.register(type: UITabBarController.self, factory: BaseTabBarController.init)
        container.register(type: UISplitViewController.self, factory: BaseSplitViewController.init)
        container.registerSingleton(factory: { TorrentService.shared })
        container.registerSingleton(factory: { PreferencesStorage.shared })
        container.registerSingleton(factory: { BackgroundService.shared })
        container.registerSingleton(factory: { DownloadEngine.shared })
        container.registerSingleton(factory: NetworkMonitoringService.init)
        container.registerSingleton(factory: TrackersListService.init)
        container.registerDaemon(factory: TorrentMonitoringService.init)
        container.registerDaemon(factory: CellularNotAllowedOverlay.init)
    }

    override func routing(in router: Router) {
        // MARK: Cells
        router.register(TorrentListItemView.self)
        router.register(TorrentDetailProgressCellView.self)

        router.register(TrackerCellView.self)

        router.register(DetailCellView.self)
        router.register(ToggleCellView.self)

        router.register(PRSwitchView.self)
        router.register(PRButtonView.self)
        router.register(PRStorageCell.self)
        router.register(PRColorPickerCell.self)
        router.register(MenuButtonCellView.self)

        // MARK: Controllers
        router.register(BaseHostingViewController<StoragePreferencesView>.self)

        router.register(TorrentListViewController<TorrentListViewModel>.self)
        router.register(DownloadsViewController<DownloadsViewModel>.self)
        router.register(DownloadItemView.self)
        router.register(TorrentDetailsViewController<TorrentDetailsViewModel>.self)
        router.register(TorrentFilesViewController<TorrentFilesViewModel>.self)
        router.register(TorrentAddViewController<TorrentAddViewModel>.self)
        router.register(TorrentTrackersViewController<TorrentTrackersViewModel>.self)

        router.register(CellularToggleSetupViewController<CellularToggleSetupViewModel>.self)

        router.register(BasePreferencesViewController<PreferencesViewModel>.self)
        router.register(BasePreferencesViewController<ProxyPreferencesViewModel>.self)
        router.register(TrackersListPreferencesViewController.self)
        router.register(TrackersListDetailsPreferencesViewController.self)
        router.register(BasePreferencesViewController<ConnectionPreferencesViewModel>.self)
        router.register(PreferencesSectionGroupingViewController.self)
    }

    override func resolveRootVC(with router: Router) -> UIViewController {
        let torrentListVC = router.resolve(TorrentListViewModel())

        let nvc = UINavigationController.resolve()
        nvc.viewControllers = [torrentListVC]
        nvc.tabBarItem = UITabBarItem(title: "Torrents".localized, image: UIImage(systemName: "arrow.down.circle"), selectedImage: UIImage(systemName: "arrow.down.circle.fill"))

        let tabBarController = BaseTabBarController()

        let downloadsViewController = router.resolve(DownloadsViewModel())
        let downloadsNVC = UINavigationController.resolve()
        downloadsNVC.viewControllers = [downloadsViewController]
        downloadsNVC.tabBarItem = UITabBarItem(
            title: "Downloads".localized,
            image: UIImage(systemName: "square.and.arrow.down"),
            selectedImage: UIImage(systemName: "square.and.arrow.down.fill")
        )

        tabBarController.viewControllers = [nvc, downloadsNVC]

        return tabBarController
    }

    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        invokeInitialSetup()
        connectionOptions.urlContexts.forEach { context in
            let url = context.url
            processURL(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach { context in
            let url = context.url
            processURL(url)
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        UIApplication.shared.applicationIconBadgeNumber = 0
        startBackgroundIfNeeded()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        UIApplication.shared.applicationIconBadgeNumber = 0
        stopBackground()
    }

    override func binding() {
        disposeBag.bind {
            tintColorBind
            appAppearanceBind
            backgroundDownloadModeBind
            backgroundStateObserverBind
        }
    }
}

private extension SceneDelegate {
    func invokeInitialSetup() {
        guard let window else { return }

        Task { @MainActor [weak window] in
            try await Task.sleep(for: .seconds(0.5))
            guard let window else { return }
            await InitialSetupFlow.startIfNeeded(in: window)
        }
    }
}
