import Foundation

// MARK: - Segment state

/// Lifecycle state of a single byte-range segment. Persisted so interrupted
/// segmented downloads can resume their exact ranges.
public enum DownloadSegmentState: String, Codable, Equatable, Sendable {
    case pending
    case downloading
    case paused
    case completed
    case failed
    case retrying
    case cancelled
}

// MARK: - Segment model

/// One independent byte range of a segmented download. The remote file is
/// split into non-overlapping ranges; each segment is fetched with its own
/// HTTP request using `Range: bytes=start-end`.
public struct DownloadSegment: Codable, Equatable, Sendable {
    public let segmentID: UUID
    public let taskID: UUID
    public let byteStart: Int64
    public let byteEnd: Int64          // inclusive (per HTTP Range semantics)
    public var downloadedBytes: Int64
    public var expectedBytes: Int64 { byteEnd - byteStart + 1 }
    public var state: DownloadSegmentState
    public var retryCount: Int
    public var lastError: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var currentSpeed: Double
    public var lastProgressTimestamp: Date?

    public init(
        segmentID: UUID = UUID(),
        taskID: UUID,
        byteStart: Int64,
        byteEnd: Int64,
        downloadedBytes: Int64 = 0,
        state: DownloadSegmentState = .pending,
        retryCount: Int = 0,
        lastError: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        currentSpeed: Double = 0,
        lastProgressTimestamp: Date? = nil
    ) {
        self.segmentID = segmentID
        self.taskID = taskID
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.downloadedBytes = downloadedBytes
        self.state = state
        self.retryCount = retryCount
        self.lastError = lastError
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.currentSpeed = currentSpeed
        self.lastProgressTimestamp = lastProgressTimestamp
    }

    /// Bytes already received (validated against the range, never negative
    /// and never beyond the range).
    public var validDownloadedBytes: Int64 {
        min(max(downloadedBytes, 0), expectedBytes)
    }

    public var isComplete: Bool { state == .completed && downloadedBytes >= expectedBytes }

    /// The next byte offset to request when resuming this segment.
    public var resumeStart: Int64 { byteStart + validDownloadedBytes }

    /// The effective HTTP range for this segment's next request.
    public var nextRangeHeader: String? {
        let start = resumeStart
        guard start <= byteEnd else { return nil }
        return "bytes=\(start)-\(byteEnd)"
    }
}

// MARK: - Segment map

/// Pure math over a set of segments: creation, resumption, validation and
/// repair. No I/O, no networking — fully unit-testable.
public struct DownloadSegmentMap: Equatable, Sendable {
    public let segments: [DownloadSegment]
    public let totalBytes: Int64

    public init(segments: [DownloadSegment], totalBytes: Int64) {
        self.segments = segments.sorted { $0.byteStart < $1.byteStart }
        self.totalBytes = totalBytes
    }

    // MARK: Creation

    /// Splits `totalBytes` into `connectionCount` roughly equal, non-overlapping
    /// ranges. Guarantees: cover [0, totalBytes), no gaps, no overlaps.
    /// Falls back to a single full-range segment for degenerate sizes.
    public static func makeSegments(totalBytes: Int64, taskID: UUID, connectionCount: Int) -> [DownloadSegment] {
        guard totalBytes > 0 else { return [] }
        let count = max(1, min(connectionCount, Int(totalBytes)))
        guard count > 1 else {
            return [DownloadSegment(taskID: taskID, byteStart: 0, byteEnd: totalBytes - 1)]
        }
        let base = totalBytes / Int64(count)
        let remainder = totalBytes % Int64(count)
        var segments: [DownloadSegment] = []
        var cursor: Int64 = 0
        for index in 0..<count {
            let size = base + (Int64(index) < remainder ? 1 : 0)
            guard size > 0 else { continue }
            let start = cursor
            let end = cursor + size - 1
            segments.append(DownloadSegment(taskID: taskID, byteStart: start, byteEnd: end))
            cursor = end + 1
        }
        // Safety: if anything above drifted, clamp the last segment.
        if let last = segments.last, last.byteEnd != totalBytes - 1 {
            let fixed = DownloadSegment(
                taskID: taskID,
                byteStart: last.byteStart,
                byteEnd: totalBytes - 1,
                downloadedBytes: last.downloadedBytes,
                state: last.state,
                retryCount: last.retryCount,
                lastError: last.lastError,
                startedAt: last.startedAt,
                completedAt: last.completedAt,
                currentSpeed: last.currentSpeed,
                lastProgressTimestamp: last.lastProgressTimestamp
            )
            segments[segments.count - 1] = fixed
        }
        return segments
    }

    /// Number of connections to use for a file of `totalBytes`, per the
    /// conservative initial policy. Not hardcoded — see `adapt`.
    public static func initialConnectionCount(totalBytes: Int64) -> Int {
        switch totalBytes {
        case ..<(50 * 1024 * 1024):   return 1
        case ..<(500 * 1024 * 1024):  return 2
        case ..<(2 * 1024 * 1024 * 1024): return 4
        default:                      return 6
        }
    }

    /// Adapts the connection count after observed failures. Never increases
    /// when the server is struggling; slowly recovers once things stabilize.
    public static func adapt(current: Int, recentFailures: Int, stablePeriods: Int) -> Int {
        let cap = 8
        if recentFailures > 0 { return max(1, current - 1) }
        if stablePeriods >= 2, current < cap { return min(cap, current + 1) }
        return max(1, current)
    }

    // MARK: Validation

    /// True when the segments cover [0, totalBytes) exactly with no overlap
    /// and no gaps.
    public func coversFileExactly() -> Bool {
        guard let first = segments.first, first.byteStart == 0 else { return false }
        var cursor: Int64 = 0
        for segment in segments {
            guard segment.byteStart == cursor else { return false }
            cursor = segment.byteEnd + 1
        }
        return cursor == totalBytes
    }

    /// Any byte covered by two or more segments (would cause duplicate bytes
    /// during assembly).
    public func overlappingRanges() -> [(DownloadSegment, DownloadSegment)] {
        var overlaps: [(DownloadSegment, DownloadSegment)] = []
        for (index, segment) in segments.enumerated() where index > 0 {
            let previous = segments[index - 1]
            if segment.byteStart <= previous.byteEnd {
                overlaps.append((previous, segment))
            }
        }
        return overlaps
    }

    /// Ranges that a completed file would be missing.
    public func missingRanges() -> [(start: Int64, end: Int64)] {
        var missing: [(Int64, Int64)] = []
        var cursor: Int64 = 0
        for segment in segments {
            if segment.byteStart > cursor {
                missing.append((cursor, segment.byteStart - 1))
            }
            cursor = max(cursor, segment.byteEnd + 1)
        }
        if cursor < totalBytes { missing.append((cursor, totalBytes - 1)) }
        return missing
    }

    /// Total bytes downloaded across all segments (clamped to ranges).
    public var downloadedBytes: Int64 {
        segments.reduce(0) { $0 + $1.validDownloadedBytes }
    }

    /// True when every segment is completed.
    public var isComplete: Bool {
        !segments.isEmpty && segments.allSatisfy { $0.isComplete }
    }

    // MARK: Resume / repair

    /// Recomputes the effective segment map for a resume. Incomplete ranges
    /// are kept (resumed from their local size); completed ranges stay; stale
    /// segments whose ranges exceed the new server size are dropped. When the
    /// server size is nil or equal, the map is returned unchanged.
    public func resumeMapping(serverSize: Int64?) -> DownloadSegmentMap {
        guard let serverSize, serverSize != totalBytes else { return self }
        guard serverSize > 0 else { return DownloadSegmentMap(segments: [], totalBytes: serverSize) }
        let usable = segments.filter { $0.byteStart < serverSize }
        let resized = DownloadSegmentMap.makeSegments(
            totalBytes: serverSize,
            taskID: usable.first?.taskID ?? UUID(),
            connectionCount: max(1, usable.count)
        )
        // Preserve completed progress where the ranges still match.
        let preserved: [DownloadSegment] = resized.map { fresh in
            if let old = usable.first(where: { $0.byteStart == fresh.byteStart && $0.byteEnd == fresh.byteEnd }),
               old.isComplete || old.downloadedBytes > 0 {
                return DownloadSegment(
                    segmentID: old.segmentID,
                    taskID: old.taskID,
                    byteStart: fresh.byteStart,
                    byteEnd: fresh.byteEnd,
                    downloadedBytes: min(old.validDownloadedBytes, fresh.expectedBytes),
                    state: old.validDownloadedBytes >= fresh.expectedBytes ? .completed : .pending,
                    retryCount: old.retryCount,
                    lastError: old.lastError,
                    startedAt: old.startedAt,
                    completedAt: old.completedAt,
                    currentSpeed: 0,
                    lastProgressTimestamp: old.lastProgressTimestamp
                )
            }
            return fresh
        }
        return DownloadSegmentMap(segments: preserved, totalBytes: serverSize)
    }

    /// Rebuilds the map after an HTTP 416: the local partial data exceeds the
    /// current server file. Truncates the last retained segment to the server
    /// size and drops everything beyond it. Returns the map and the list of
    /// segment IDs that were discarded.
    public func repairingAfter416(serverSize: Int64) -> (map: DownloadSegmentMap, discarded: [UUID]) {
        guard serverSize > 0, serverSize <= totalBytes else {
            return (DownloadSegmentMap(segments: [], totalBytes: max(0, serverSize)), segments.map(\.segmentID))
        }
        var kept: [DownloadSegment] = []
        var discarded: [UUID] = []
        for segment in segments {
            if segment.byteEnd < serverSize {
                kept.append(segment)
            } else if segment.byteStart < serverSize {
                let truncated = DownloadSegment(
                    segmentID: segment.segmentID,
                    taskID: segment.taskID,
                    byteStart: segment.byteStart,
                    byteEnd: serverSize - 1,
                    downloadedBytes: 0,
                    state: .pending,
                    retryCount: segment.retryCount,
                    lastError: segment.lastError,
                    startedAt: segment.startedAt,
                    completedAt: nil,
                    currentSpeed: 0,
                    lastProgressTimestamp: nil
                )
                kept.append(truncated)
            } else {
                discarded.append(segment.segmentID)
            }
        }
        if kept.isEmpty {
            let fresh = DownloadSegmentMap.makeSegments(totalBytes: serverSize, taskID: segments.first?.taskID ?? UUID(), connectionCount: 1)
            return (DownloadSegmentMap(segments: fresh, totalBytes: serverSize), discarded)
        }
        let map = DownloadSegmentMap(segments: kept, totalBytes: serverSize)
        return (map, discarded)
    }

    /// Segments still needing transfer (not completed, not cancelled).
    public var pendingSegments: [DownloadSegment] {
        segments.filter { $0.state != .completed && $0.state != .cancelled }
    }
}
