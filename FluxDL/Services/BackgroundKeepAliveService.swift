import Foundation
import UIKit
import AVFoundation
import CoreLocation

public protocol BackgroundKeepAliveServiceProtocol: AnyObject {
    /// Each subsystem reports ONLY its own domain through a private slot.
    /// Slots are updated independently, so one subsystem can never silently
    /// cancel another's keep-alive claim (e.g. a download tick must not kill
    /// the browser's background keep-alive and vice versa).
    func updateDownloadsKeepAlive(_ active: Bool)
    func updateBrowserKeepAlive(_ active: Bool)
    func updateTorrentsKeepAlive(_ active: Bool)
    func stopAllKeepAlive()
}

public final class BackgroundKeepAliveService: NSObject, BackgroundKeepAliveServiceProtocol, CLLocationManagerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private var locationManager: CLLocationManager?

    private let downloadsKeepAliveKey = "fluxdl_bg_keepalive_downloads"
    private let browserKeepAliveKey = "fluxdl_bg_keepalive_browser"
    private let torrentsKeepAliveKey = "fluxdl_bg_keepalive_torrents"

    /// Independent keep-alive claims owned by the downloads engine, the
    /// browser tab manager and the torrent service. Each setter touches only
    /// its own slot, then re-evaluates; repeated lifecycle events never create
    /// duplicate players/listeners.
    private var activeDownloads: Bool = false
    private var activeBrowser: Bool = false
    private var activeTorrents: Bool = false

    /// Diagnostic/test-observable: whether keep-alive is currently running.
    public private(set) var isKeepAliveRunning: Bool = false

    public override init() {
        super.init()
    }

    public func updateDownloadsKeepAlive(_ active: Bool) {
        updateDownloadsKeepAlive(active, appState: UIApplication.shared.applicationState)
    }

    public func updateBrowserKeepAlive(_ active: Bool) {
        updateBrowserKeepAlive(active, appState: UIApplication.shared.applicationState)
    }

    public func updateTorrentsKeepAlive(_ active: Bool) {
        updateTorrentsKeepAlive(active, appState: UIApplication.shared.applicationState)
    }

    /// Testable variants — `appState` is injectable so unit tests can exercise
    /// the background branch without running the app backgrounded.
    func updateDownloadsKeepAlive(_ active: Bool, appState: UIApplication.State) {
        activeDownloads = active
        evaluate(appState: appState)
    }

    func updateBrowserKeepAlive(_ active: Bool, appState: UIApplication.State) {
        activeBrowser = active
        evaluate(appState: appState)
    }

    func updateTorrentsKeepAlive(_ active: Bool, appState: UIApplication.State) {
        activeTorrents = active
        evaluate(appState: appState)
    }

    private func evaluate(appState: UIApplication.State) {
        // Keep-alive (audio/location) is ONLY required when app is in the BACKGROUND.
        // In the foreground, iOS natively keeps the process active — running
        // audio/GPS in foreground wastes battery and causes heating.
        guard appState == .background else {
            stopAllKeepAlive()
            return
        }

        let downloadsKeepAliveEnabled = UserDefaults.standard.object(forKey: downloadsKeepAliveKey) != nil
            ? UserDefaults.standard.bool(forKey: downloadsKeepAliveKey) : true
        let browserKeepAliveEnabled = UserDefaults.standard.bool(forKey: browserKeepAliveKey)
        let torrentsKeepAliveEnabled = UserDefaults.standard.object(forKey: torrentsKeepAliveKey) != nil
            ? UserDefaults.standard.bool(forKey: torrentsKeepAliveKey) : true

        let shouldKeepAliveDownloads = downloadsKeepAliveEnabled && activeDownloads
        let shouldKeepAliveBrowser = browserKeepAliveEnabled && activeBrowser
        let shouldKeepAliveTorrents = torrentsKeepAliveEnabled && activeTorrents

        if shouldKeepAliveDownloads || shouldKeepAliveBrowser || shouldKeepAliveTorrents {
            startKeepAlive()
            isKeepAliveRunning = true
        } else {
            stopAllKeepAlive()
            isKeepAliveRunning = false
        }
    }

    private func startKeepAlive() {
        startSilentAudio()
        startLocationUpdates()
    }

    public func stopAllKeepAlive() {
        stopSilentAudio()
        stopLocationUpdates()
        isKeepAliveRunning = false
    }

    // MARK: - Silent Audio Background Loop

    private func startSilentAudio() {
        // Idempotent: a playing player is never duplicated.
        guard audioPlayer == nil || audioPlayer?.isPlaying == false else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            let silentWavData = createSilentWavData()
            audioPlayer = try AVAudioPlayer(data: silentWavData)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01
            audioPlayer?.play()
            print("FluxDL BackgroundService: Background silent audio started.")
        } catch {
            print("FluxDL BackgroundService: Audio keep-alive error: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        if let player = audioPlayer, player.isPlaying {
            player.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("FluxDL BackgroundService: Background silent audio stopped.")
        }
        audioPlayer = nil
    }

    // MARK: - Location Updates Background Keep-Alive

    private func startLocationUpdates() {
        // Idempotent: only one manager at a time.
        guard locationManager == nil else { return }
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager?.distanceFilter = 99999
        locationManager?.allowsBackgroundLocationUpdates = true
        locationManager?.pausesLocationUpdatesAutomatically = false
        locationManager?.requestWhenInUseAuthorization()
        locationManager?.startUpdatingLocation()
        print("FluxDL BackgroundService: Background location keep-alive started.")
    }

    private func stopLocationUpdates() {
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        print("FluxDL BackgroundService: Background location keep-alive stopped.")
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Keeps process alive without heavy processing
    }

    // MARK: - Silent WAV Buffer Generator

    private func createSilentWavData() -> Data {
        let sampleRate = 44100
        let duration = 1.0
        let numSamples = Int(Double(sampleRate) * duration)
        let dataSize = numSamples * 2
        let fileSize = 44 + dataSize

        var header = Data()
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(contentsOf: UInt32(fileSize - 8).littleEndianBytes)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(contentsOf: UInt32(16).littleEndianBytes)
        header.append(contentsOf: UInt16(1).littleEndianBytes)
        header.append(contentsOf: UInt16(1).littleEndianBytes)
        header.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        header.append(contentsOf: UInt32(sampleRate * 2).littleEndianBytes)
        header.append(contentsOf: UInt16(2).littleEndianBytes)
        header.append(contentsOf: UInt16(16).littleEndianBytes)
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        header.append(contentsOf: UInt32(dataSize).littleEndianBytes)

        let pcmData = Data(count: dataSize)
        return header + pcmData
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}