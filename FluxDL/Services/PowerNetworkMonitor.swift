import Foundation
import UIKit
import Combine
import Network

public protocol PowerNetworkMonitorProtocol: AnyObject {
    var isLowBattery: Bool { get }
    var isLowPowerMode: Bool { get }
    var isWiFiOnlyEnabled: Bool { get set }
    var bandwidthLimitKBps: Int { get set }
    func startMonitoring(engine: DownloadEngineProtocol)
}

@MainActor
public final class PowerNetworkMonitor: ObservableObject, PowerNetworkMonitorProtocol {
    @Published public private(set) var isLowBattery: Bool = false
    @Published public private(set) var isLowPowerMode: Bool = false

    @Published public var isWiFiOnlyEnabled: Bool {
        didSet { UserDefaults.standard.set(isWiFiOnlyEnabled, forKey: "fluxdl_wifi_only") }
    }
    @Published public var bandwidthLimitKBps: Int {
        didSet { UserDefaults.standard.set(bandwidthLimitKBps, forKey: "fluxdl_bandwidth_limit") }
    }

    private var cancellables = Set<AnyCancellable>()
    private weak var engine: DownloadEngineProtocol?

    private let lowBatteryPauseKey = "fluxdl_low_battery_pause"

    /// Tasks auto-paused by this monitor (low battery / LPM / cellular with
    /// WiFi-only). They are restored automatically once the condition clears;
    /// tasks the user paused manually are never touched.
    private var autoPausedTaskIDs: Set<UUID> = []

    private var pathMonitor: NWPathMonitor?
    /// Last known path, kept so the WiFi-only toggle can be re-applied
    /// immediately when the user flips it in Settings.
    private var lastPath: NWPath?

    public init() {
        self.isWiFiOnlyEnabled    = UserDefaults.standard.bool(forKey: "fluxdl_wifi_only")
        self.bandwidthLimitKBps   = UserDefaults.standard.integer(forKey: "fluxdl_bandwidth_limit")

        UIDevice.current.isBatteryMonitoringEnabled = true

        // Battery / LPM notifications arrive on system queues — receive on main
        NotificationCenter.default
            .publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateBatteryState() } }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSNotification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateBatteryState() } }
            .store(in: &cancellables)

        // Settings toggles are plain UserDefaults keys (written by the Settings
        // tab's @AppStorage). Re-read them so toggling Wi-Fi Only / Low Battery
        // / threshold takes effect immediately instead of on next launch or
        // next battery/path event. Same pattern as BrowserTabManager.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.handleUserDefaultsChange() } }
            .store(in: &cancellables)
    }

    /// Re-reads settings written directly to UserDefaults and re-applies them.
    /// Equality guards prevent feedback loops with the published didSet
    /// writers (which persist the same keys back).
    func handleUserDefaultsChange() {
        let storedWiFiOnly = UserDefaults.standard.bool(forKey: "fluxdl_wifi_only")
        if storedWiFiOnly != isWiFiOnlyEnabled {
            isWiFiOnlyEnabled = storedWiFiOnly
        }
        let storedBandwidth = UserDefaults.standard.integer(forKey: "fluxdl_bandwidth_limit")
        if storedBandwidth != bandwidthLimitKBps {
            bandwidthLimitKBps = storedBandwidth
        }

        // Re-evaluate battery and connectivity with the fresh settings.
        updateBatteryState()
        if let lastPath {
            updatePathState(lastPath)
        }
    }

    public func startMonitoring(engine: DownloadEngineProtocol) {
        self.engine = engine
        startPathMonitoring()
    }

    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updatePathState(path)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.rakib.FluxDL.power.path"))
    }

    /// Low-battery auto-pause toggle. The absent-key default (true) must match
    /// the Settings tab's @AppStorage default, so a fresh install behaves the
    /// way the UI shows it. Extracted for deterministic testing.
    func lowBatteryAutoPauseEnabled() -> Bool {
        UserDefaults.standard.object(forKey: lowBatteryPauseKey) != nil
            ? UserDefaults.standard.bool(forKey: lowBatteryPauseKey) : true
    }

    private func updateBatteryState() {
        let level    = UIDevice.current.batteryLevel
        let state    = UIDevice.current.batteryState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Read user-configurable threshold (stored as Int percent, e.g. 20 means 20%)
        let thresholdPercent = UserDefaults.standard.integer(forKey: "fluxdl_battery_threshold")
        let threshold: Float = thresholdPercent > 0 ? Float(thresholdPercent) / 100.0 : 0.20
        let lowBat   = level > 0 && level < threshold && state == .unplugged

        isLowBattery  = lowBat
        isLowPowerMode = lowPower

        // Auto-pause if low battery or Low Power Mode is on — and reliably
        // auto-resume the exact tasks this monitor paused once it clears
        // (or once the user disables the auto-pause toggle).
        let shouldAutoPause = lowBatteryAutoPauseEnabled()
        if shouldAutoPause, (lowBat || lowPower) {
            pauseAllDownloading()
        } else if !shouldAutoPause || (!lowBat && !lowPower) {
            resumeAutoPausedTasks()
        }
    }

    private func updatePathState(_ path: NWPath) {
        lastPath = path
        guard isWiFiOnlyEnabled else {
            // Setting switched off while paused by it: restore what we paused.
            resumeAutoPausedTasks()
            return
        }
        if path.usesInterfaceType(.cellular), path.status == .satisfied || path.status == .requiresConnection {
            pauseAllDownloading()
        } else if !path.usesInterfaceType(.cellular) {
            resumeAutoPausedTasks()
        }
    }

    private func pauseAllDownloading() {
        guard let engine else { return }
        for task in engine.tasks where task.status == .downloading {
            autoPausedTaskIDs.insert(task.id)
            engine.pauseDownload(id: task.id)
        }
    }

    private func resumeAutoPausedTasks() {
        guard let engine, !autoPausedTaskIDs.isEmpty else { return }
        let ids = autoPausedTaskIDs
        autoPausedTaskIDs.removeAll()
        for id in ids {
            if engine.tasks.first(where: { $0.id == id })?.status == .paused {
                engine.resumeDownload(id: id)
            }
        }
    }
}