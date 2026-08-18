import Foundation

// MARK: - Health states

/// Stable health classification shown in the Download tab. Updates are
/// throttled so the UI never repaints faster than necessary.
public enum DownloadHealthState: String, Codable, Equatable, Sendable {
    case unknown = "Unknown"
    case excellent = "Excellent"
    case good = "Good"
    case degraded = "Degraded"
    case poor = "Poor"
    case stalled = "Stalled"
    case failed = "Failed"
}

/// Lightweight, UI-ready snapshot emitted by the monitor (throttled).
public struct DownloadHealthSnapshot: Equatable, Sendable {
    public let state: DownloadHealthState
    public let averageSpeed: Double
    public let currentSpeed: Double
    public let latency: TimeInterval?
    public let stallDuration: TimeInterval?
    public let sampleCount: Int
    public let updatedAt: Date

    public init(
        state: DownloadHealthState,
        averageSpeed: Double,
        currentSpeed: Double,
        latency: TimeInterval? = nil,
        stallDuration: TimeInterval? = nil,
        sampleCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.state = state
        self.averageSpeed = averageSpeed
        self.currentSpeed = currentSpeed
        self.latency = latency
        self.stallDuration = stallDuration
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }

    public var isDownloading: Bool {
        state != .unknown && state != .stalled && state != .failed
    }
}

// MARK: - Monitor

/// Tracks throughput, computes a stable exponential moving average, detects
/// stalls, and only reports state transitions (throttled to the UI rate).
/// `@unchecked Sendable` — all mutable state is guarded by `lock`.
public final class DownloadHealthMonitor: @unchecked Sendable {

    public struct Config: Sendable {
        /// Smoothing factor for the exponential moving average (0...1).
        public var smoothing: Double
        /// Bytes per second below which the transfer is considered stalled.
        public var stallThreshold: Double
        /// Seconds without meaningful progress before declaring a stall.
        public var stallTimeout: TimeInterval
        /// Minimum seconds between UI-facing snapshots.
        public var throttleInterval: TimeInterval
        /// Seconds of quiet at transfer end after which the monitor resets.
        public var quietResetInterval: TimeInterval

        public init(
            smoothing: Double = 0.2,
            stallThreshold: Double = 8_192,
            stallTimeout: TimeInterval = 4,
            throttleInterval: TimeInterval = 0.8,
            quietResetInterval: TimeInterval = 60
        ) {
            self.smoothing = smoothing
            self.stallThreshold = stallThreshold
            self.stallTimeout = stallTimeout
            self.throttleInterval = throttleInterval
            self.quietResetInterval = quietResetInterval
        }
    }

    private let lock = NSLock()
    private let config: Config
    private var samples: [(bytes: Int64, date: Date)] = []
    private var lastWindow: (startBytes: Int64, startDate: Date)?
    private var averageSpeed: Double = 0
    private var lastBytes: Int64 = 0
    private var lastUpdate = Date()
    private var lastStallStart: Date?
    private var lastEmittedState: DownloadHealthState = .unknown
    private var lastEmittedAt = Date.distantPast

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Records `bytes` received since the last call (or cumulative when
    /// `cumulative` is true).
    public func record(bytes: Int64, at date: Date = Date(), cumulative: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let current: Int64 = cumulative ? bytes : lastBytes + bytes
        if current < lastBytes { current = lastBytes }
        let delta = current - lastBytes
        lastBytes = current

        if let window = lastWindow {
            let elapsed = date.timeIntervalSince(window.startDate)
            if elapsed >= 1.0 {
                let speed = Double(delta) / max(elapsed, 0.001)
                if averageSpeed == 0 {
                    averageSpeed = speed
                } else {
                    averageSpeed = averageSpeed + (speed - averageSpeed) * config.smoothing
                }
                samples.append((delta, date))
                if samples.count > 30 { samples.removeFirst(samples.count - 30) }
                lastWindow = (current, date)
            }
        } else {
            lastWindow = (current, date)
            samples.append((delta, date))
        }
        lastUpdate = date
    }

    /// Returns a snapshot when enough time has passed since the last emission,
    /// else nil (throttling). Call this at the UI cadence.
    public func snapshot(at date: Date = Date()) -> DownloadHealthSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard date.timeIntervalSince(lastEmittedAt) >= config.throttleInterval else { return nil }

        let elapsedSinceProgress = date.timeIntervalSince(lastUpdate)
        let speed = currentSpeed(at: date)
        var stallDuration: TimeInterval? = nil
        var state: DownloadHealthState

        if elapsedSinceProgress >= config.stallTimeout {
            if lastStallStart == nil { lastStallStart = date }
            stallDuration = date.timeIntervalSince(lastStallStart!)
            state = (averageSpeed > 0 && speed < config.stallThreshold) ? .stalled : .unknown
        } else {
            lastStallStart = nil
            if speed == 0 && samples.isEmpty {
                state = .unknown
            } else if averageSpeed >= 4_000_000 {
                state = .excellent
            } else if averageSpeed >= 1_000_000 {
                state = .good
            } else if averageSpeed >= 100_000 {
                state = .degraded
            } else if averageSpeed > 0 {
                state = .poor
            } else {
                state = .unknown
            }
        }

        if elapsedSinceProgress >= config.quietResetInterval {
            resetLocked()
            state = .unknown
            stallDuration = nil
        }

        let snapshot = DownloadHealthSnapshot(
            state: state,
            averageSpeed: averageSpeed,
            currentSpeed: speed,
            latency: nil,
            stallDuration: stallDuration,
            sampleCount: samples.count,
            updatedAt: date
        )
        lastEmittedState = state
        lastEmittedAt = date
        return snapshot
    }

    /// Immediate, non-throttled view (for tests and one-off UI reads).
    public func immediateSnapshot(at date: Date = Date()) -> DownloadHealthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DownloadHealthSnapshot(
            state: lastEmittedState,
            averageSpeed: averageSpeed,
            currentSpeed: currentSpeed(at: date),
            sampleCount: samples.count,
            updatedAt: date
        )
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        resetLocked()
    }

    private func resetLocked() {
        samples.removeAll()
        lastWindow = nil
        averageSpeed = 0
        lastBytes = 0
        lastUpdate = Date()
        lastStallStart = nil
        lastEmittedAt = Date.distantPast
    }

    /// Bytes per second over the last measurement window (or 0 when stale).
    private func currentSpeed(at date: Date) -> Double {
        guard let window = lastWindow else { return 0 }
        let elapsed = date.timeIntervalSince(window.startDate)
        guard elapsed < config.stallTimeout + 2 else { return 0 }
        let delta = lastBytes - window.startBytes
        guard delta >= 0, elapsed > 0.001 else { return 0 }
        return Double(delta) / elapsed
    }

    /// Static classification helper for tests and reporting.
    public static func classify(averageSpeed: Double) -> DownloadHealthState {
        if averageSpeed >= 4_000_000 { return .excellent }
        if averageSpeed >= 1_000_000 { return .good }
        if averageSpeed >= 100_000 { return .degraded }
        if averageSpeed > 0 { return .poor }
        return .unknown
    }
}
