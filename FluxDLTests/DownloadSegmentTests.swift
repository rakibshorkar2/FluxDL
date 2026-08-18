import XCTest
@testable import FluxDL

final class DownloadSegmentTests: XCTestCase {

    private let taskID = UUID()

    // MARK: - Creation

    func testMakeSegmentsCoversFileExactly() {
        for total in [1, 2, 10, 100, 1024 * 1024, 500 * 1024 * 1024, 3 * 1024 * 1024 * 1024] as [Int64] {
            let map = DownloadSegmentMap(
                segments: DownloadSegmentMap.makeSegments(totalBytes: total, taskID: taskID, connectionCount: 4),
                totalBytes: total
            )
            XCTAssertTrue(map.coversFileExactly(), "segments must cover \(total) exactly")
            XCTAssertTrue(map.overlappingRanges().isEmpty, "no overlaps for \(total)")
            XCTAssertTrue(map.missingRanges().isEmpty, "no gaps for \(total)")
            XCTAssertEqual(map.segments.reduce(0) { $0 + $1.expectedBytes }, total)
        }
    }

    func testMakeSegmentsSingleConnection() {
        let segments = DownloadSegmentMap.makeSegments(totalBytes: 10_000, taskID: taskID, connectionCount: 1)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].byteStart, 0)
        XCTAssertEqual(segments[0].byteEnd, 9_999)
    }

    func testMakeSegmentsMoreConnectionsThanBytes() {
        let segments = DownloadSegmentMap.makeSegments(totalBytes: 2, taskID: taskID, connectionCount: 8)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.expectedBytes).reduce(0, +), 2)
    }

    func testMakeSegmentsZeroBytes() {
        XCTAssertTrue(DownloadSegmentMap.makeSegments(totalBytes: 0, taskID: taskID, connectionCount: 4).isEmpty)
    }

    func testMakeSegmentsRemainderDistribution() {
        // 10 bytes across 3 connections → sizes 4, 3, 3
        let segments = DownloadSegmentMap.makeSegments(totalBytes: 10, taskID: taskID, connectionCount: 3)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].expectedBytes, 4)
        XCTAssertEqual(segments[1].expectedBytes, 3)
        XCTAssertEqual(segments[2].expectedBytes, 3)
        XCTAssertEqual(segments[0].byteStart, 0)
        XCTAssertEqual(segments[2].byteEnd, 9)
    }

    // MARK: - Connection policy

    func testInitialConnectionCountBySize() {
        XCTAssertEqual(DownloadSegmentMap.initialConnectionCount(totalBytes: 10 * 1024 * 1024), 1)
        XCTAssertEqual(DownloadSegmentMap.initialConnectionCount(totalBytes: 100 * 1024 * 1024), 2)
        XCTAssertEqual(DownloadSegmentMap.initialConnectionCount(totalBytes: 1 * 1024 * 1024 * 1024), 4)
        XCTAssertEqual(DownloadSegmentMap.initialConnectionCount(totalBytes: 4 * 1024 * 1024 * 1024), 6)
    }

    func testAdaptConnectionCount() {
        // Failures must reduce (never increase) the count.
        XCTAssertEqual(DownloadSegmentMap.adapt(current: 6, recentFailures: 1, stablePeriods: 0), 5)
        XCTAssertEqual(DownloadSegmentMap.adapt(current: 2, recentFailures: 1, stablePeriods: 0), 1)
        XCTAssertEqual(DownloadSegmentMap.adapt(current: 1, recentFailures: 1, stablePeriods: 0), 1)
        // Stability may slowly raise the count again, up to the cap.
        XCTAssertEqual(DownloadSegmentMap.adapt(current: 4, recentFailures: 0, stablePeriods: 2), 5)
        XCTAssertEqual(DownloadSegmentMap.adapt(current: 8, recentFailures: 0, stablePeriods: 9), 8)
    }

    // MARK: - Range math

    func testResumeStartAndNextRange() {
        var segment = DownloadSegment(taskID: taskID, byteStart: 100, byteEnd: 199)
        XCTAssertEqual(segment.resumeStart, 100)
        XCTAssertEqual(segment.nextRangeHeader, "bytes=100-199")

        segment.downloadedBytes = 25
        XCTAssertEqual(segment.resumeStart, 125)
        XCTAssertEqual(segment.nextRangeHeader, "bytes=125-199")

        segment.downloadedBytes = 100
        XCTAssertEqual(segment.resumeStart, 200)
        XCTAssertNil(segment.nextRangeHeader, "fully received segments have no next range")
    }

    func testDownloadedBytesClampedToRange() {
        var segment = DownloadSegment(taskID: taskID, byteStart: 0, byteEnd: 99)
        segment.downloadedBytes = 500
        XCTAssertEqual(segment.validDownloadedBytes, 100)

        segment.downloadedBytes = -10
        XCTAssertEqual(segment.validDownloadedBytes, 0)
    }

    // MARK: - Resume mapping

    func testResumeMappingPreservesCompletedRanges() {
        let segments = DownloadSegmentMap.makeSegments(totalBytes: 1_000, taskID: taskID, connectionCount: 4)
        var completed = segments[0]
        completed.state = .completed
        completed.downloadedBytes = completed.expectedBytes
        var partial = segments[1]
        partial.downloadedBytes = 10

        let map = DownloadSegmentMap(
            segments: [completed, partial, segments[2], segments[3]],
            totalBytes: 1_000
        )
        let resumed = map.resumeMapping(serverSize: 1_000)
        XCTAssertEqual(resumed.totalBytes, 1_000)
        XCTAssertEqual(resumed.segments[0].state, .completed)
        XCTAssertEqual(resumed.segments[1].downloadedBytes, 10)
    }

    func testResumeMappingShrunkServer() {
        let segments = DownloadSegmentMap.makeSegments(totalBytes: 1_000, taskID: taskID, connectionCount: 4)
        let map = DownloadSegmentMap(segments: segments, totalBytes: 1_000)
        let resumed = map.resumeMapping(serverSize: 700)
        XCTAssertEqual(resumed.totalBytes, 700)
        XCTAssertTrue(resumed.coversFileExactly())
        // Every retained segment stays within the new server size.
        for segment in resumed.segments {
            XCTAssertLessThan(segment.byteEnd, 700)
        }
    }

    // MARK: - 416 repair

    func testRepairingAfter416TruncatesOverlappingSegment() {
        let segments = DownloadSegmentMap.makeSegments(totalBytes: 1_000, taskID: taskID, connectionCount: 4)
        let map = DownloadSegmentMap(segments: segments, totalBytes: 1_000)
        let repaired = map.repairingAfter416(serverSize: 650)
        XCTAssertEqual(repaired.map.totalBytes, 650)
        XCTAssertTrue(repaired.map.coversFileExactly())
        // The segment overlapping 650 is truncated; anything beyond is dropped.
        for segment in repaired.map.segments {
            XCTAssertLessThan(segment.byteEnd, 650)
        }
    }

    func testRepairingAfter416ServerShrankToNothing() {
        let segments = DownloadSegmentMap.makeSegments(totalBytes: 1_000, taskID: taskID, connectionCount: 4)
        let map = DownloadSegmentMap(segments: segments, totalBytes: 1_000)
        let repaired = map.repairingAfter416(serverSize: 0)
        XCTAssertTrue(repaired.map.segments.isEmpty)
    }

    func testSegmentCodableRoundTrip() {
        var segment = DownloadSegment(taskID: taskID, byteStart: 10, byteEnd: 99)
        segment.downloadedBytes = 5
        segment.state = .paused
        segment.retryCount = 2
        segment.lastError = "timed out"

        let data = try! JSONEncoder().encode(segment)
        let decoded = try! JSONDecoder().decode(DownloadSegment.self, from: data)
        XCTAssertEqual(decoded, segment)
        XCTAssertEqual(decoded.nextRangeHeader, "bytes=15-99")
    }
}
