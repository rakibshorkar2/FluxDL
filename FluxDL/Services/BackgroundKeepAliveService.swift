import Foundation
import UIKit
import AVFoundation
import CoreLocation

public protocol BackgroundKeepAliveServiceProtocol: AnyObject {
    func updateKeepAliveState(hasActiveDownloads: Bool, isBrowserActive: Bool)
    func stopAllKeepAlive()
}

public final class BackgroundKeepAliveService: NSObject, BackgroundKeepAliveServiceProtocol, CLLocationManagerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    
    private let downloadsKeepAliveKey = "fluxdl_bg_keepalive_downloads"
    private let browserKeepAliveKey = "fluxdl_bg_keepalive_browser"
    
    public override init() {
        super.init()
    }
    
    public func updateKeepAliveState(hasActiveDownloads: Bool, isBrowserActive: Bool) {
        // Keep-alive (audio/location) is ONLY required when app is in the BACKGROUND.
        // In the foreground, iOS natively keeps the process active — running audio/GPS in foreground wastes battery and causes heating.
        guard UIApplication.shared.applicationState == .background else {
            stopAllKeepAlive()
            return
        }
        
        let downloadsKeepAliveEnabled = UserDefaults.standard.object(forKey: downloadsKeepAliveKey) != nil
            ? UserDefaults.standard.bool(forKey: downloadsKeepAliveKey) : true
        let browserKeepAliveEnabled = UserDefaults.standard.bool(forKey: browserKeepAliveKey)
        
        let shouldKeepAliveDownloads = downloadsKeepAliveEnabled && hasActiveDownloads
        let shouldKeepAliveBrowser = browserKeepAliveEnabled && isBrowserActive
        
        if shouldKeepAliveDownloads || shouldKeepAliveBrowser {
            startKeepAlive()
        } else {
            stopAllKeepAlive()
        }
    }
    
    private func startKeepAlive() {
        startSilentAudio()
        startLocationUpdates()
    }
    
    public func stopAllKeepAlive() {
        stopSilentAudio()
        stopLocationUpdates()
    }
    
    // MARK: - Silent Audio Background Loop
    
    private func startSilentAudio() {
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
        print("FluxDL BackgroundService: Location keep-alive stopped.")
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
