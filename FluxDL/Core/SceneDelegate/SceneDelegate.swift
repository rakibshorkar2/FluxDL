//
//  SceneDelegate.swift
//  iTorrent
//
//  Created by Daniil Vinogradov on 29/10/2023.
//

import LibTorrent
import MvvmFoundation
import SwiftUI
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

        tabBarController.viewControllers = [
            nvc,
            makeSwiftUITab(DownloadsView(), title: "Downloads", icon: "arrow.down.circle.fill"),
            makeSwiftUITab(BrowserView(), title: "Browser", icon: "globe"),
            makeSwiftUITab(HistoryView(), title: "History", icon: "clock.fill"),
            makeSwiftUITab(SettingsView(), title: "Settings", icon: "gearshape.fill"),
        ]

        return tabBarController
    }

    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        invokeInitialSetup()
        connectionOptions.urlContexts.forEach { context in
            let url = context.url
            processURL(url)
        }
        startFluxDLServices()
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

        MainActor.assumeIsolated {
            let container = ServiceContainer.shared
            let tasks = container.downloadEngine.tasks
            container.liveActivityManager.handleAppBackgrounding(tasks: tasks)
            container.backgroundKeepAliveService.updateKeepAliveState(
                hasActiveDownloads: tasks.contains { $0.status == .downloading },
                isBrowserActive: false
            )
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        UIApplication.shared.applicationIconBadgeNumber = 0
        stopBackground()

        MainActor.assumeIsolated {
            let container = ServiceContainer.shared
            container.backgroundKeepAliveService.stopAllKeepAlive()
            container.liveActivityManager.handleAppForegrounding()
            container.clipboardService.checkClipboardOnAppActive()
        }
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

    func startFluxDLServices() {
        Task { @MainActor in
            await ServiceContainer.shared.notificationService.requestAuthorization()
            await ServiceContainer.shared.restorationService.restoreActiveTasks(
                engine: ServiceContainer.shared.downloadEngine as! DownloadEngine
            )
        }
        installClipboardBanner()
    }

    func installClipboardBanner() {
        guard let window, let rootViewController = window.rootViewController else { return }

        let hostingController = UIHostingController(rootView: ClipboardBannerView { [weak self] url in
            MainActor.assumeIsolated {
                _ = ServiceContainer.shared.downloadEngine.startDownload(url: url, filename: nil)
                ServiceContainer.shared.clipboardService.dismissDetectedURL()
                (self?.window?.rootViewController as? UITabBarController)?.selectedIndex = 1
            }
        })
        hostingController.view.backgroundColor = .clear
        rootViewController.addChild(hostingController)
        rootViewController.view.addSubview(hostingController.view)
        hostingController.view.frame = rootViewController.view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostingController.didMove(toParent: rootViewController)
    }

    func makeSwiftUITab<Content: View>(_ view: Content, title: String, icon: String) -> UIViewController {
        let hostingController = UIHostingController(
            rootView: MainActor.assumeIsolated {
                view.preferredColorScheme(ServiceContainer.shared.themeService.colorScheme)
            }
        )
        hostingController.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: icon),
            selectedImage: UIImage(systemName: icon)
        )
        return hostingController
    }
}
