import XCTest
@testable import FluxDL

final class DownloadHealthMonitorTests: XCTestCase {

    func testAverageSpeedSmoothing() {
        let monitor = DownloadHealthMonitor()
        let t0 = Date()
        // 2 MB/s for 4 seconds
        for second in 1...4 {
            monitor.record(bytes: 2 * 1024 * 1024, at: t0.addingTimeInterval(TimeInterval(second)))
        }
        let snapshot = monitor.immediateSnapshot(at: t0.addingTimeInterval(5))
        XCTAssertGreaterThan(snapshot.averageSpeed, 1.5 * 1024 * 1024)
        XCTAssertLessThan(snapshot.averageSpeed, 2.5 * 1024 * 1024)
    }

    func testStallDetection() {
        let monitor = DownloadHealthMonitor()
        let t0 = Date()
        monitor.record(bytes: 5 * 1024 * 1024, at: t0)
        monitor.record(bytes: 5 * 1024 * 1024, at: t0.addingTimeInterval(1))
        // No progress for a while → stall
        let snapshot = monitor.snapshot(at: t0.addingTimeInterval(6))
        XCTAssertEqual(snapshot?.state, .stalled)
        XCTAssertNotNil(snapshot?.stallDuration)
    }

    func testHealthyTransferIsGoodOrBetter() {
        let monitor = DownloadHealthMonitor()
        let t0 = Date()
        for second in 1...3 {
            monitor.record(bytes: 4 * 1024 * 1024, at: t0.addingTimeInterval(TimeInterval(second)))
        }
        let snapshot = monitor.snapshot(at: t0.addingTimeInterval(3.5))
        let state = snapshot?.state ?? .unknown
        XCTAssertTrue(state == .excellent || state == .good, "expected excellent/good, got \(state)")
    }

    func testThrottlingReturnsNilBetweenEmissions() {
        let monitor = DownloadHealthMonitor(config: DownloadHealthMonitor.Config(throttleInterval: 0.8))
        let t0 = Date()
        monitor.record(bytes: 1024 * 1024, at: t0)
        XCTAssertNotNil(monitor.snapshot(at: t0))
        XCTAssertNil(monitor.snapshot(at: t0.addingTimeInterval(0.3)), "second snapshot within the throttle window must be nil")
        XCTAssertNotNil(monitor.snapshot(at: t0.addingTimeInterval(0.9)))
    }

    func testResetClearsState() {
        let monitor = DownloadHealthMonitor()
        let t0 = Date()
        monitor.record(bytes: 8 * 1024 * 1024, at: t0)
        monitor.record(bytes: 8 * 1024 * 1024, at: t0.addingTimeInterval(1))
        XCTAssertGreaterThan(monitor.immediateSnapshot().averageSpeed, 0)
        monitor.reset()
        XCTAssertEqual(monitor.immediateSnapshot().averageSpeed, 0)
    }

    func testCumulativeRecording() {
        let monitor = DownloadHealthMonitor()
        let t0 = Date()
        monitor.record(bytes: 2 * 1024 * 1024, at: t0, cumulative: true)
        monitor.record(bytes: 4 * 1024 * 1024, at: t0.addingTimeInterval(1), cumulative: true)
        let snapshot = monitor.immediateSnapshot(at: t0.addingTimeInterval(2))
        XCTAssertGreaterThan(snapshot.averageSpeed, 1 * 1024 * 1024)
    }

    func testStaticClassification() {
        XCTAssertEqual(DownloadHealthMonitor.classify(averageSpeed: 8_000_000), .excellent)
        XCTAssertEqual(DownloadHealthMonitor.classify(averageSpeed: 2_000_000), .good)
        XCTAssertEqual(DownloadHealthMonitor.classify(averageSpeed: 500_000), .degraded)
        XCTAssertEqual(DownloadHealthMonitor.classify(averageSpeed: 50_000), .poor)
        XCTAssertEqual(DownloadHealthMonitor.classify(averageSpeed: 0), .unknown)
    }
}
