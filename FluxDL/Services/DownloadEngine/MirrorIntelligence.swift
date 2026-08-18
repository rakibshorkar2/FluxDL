import Foundation

// MARK: - Mirror intelligence

/// Per-mirror scoring used when the primary URL fails. Scores combine latency,
/// throughput, success/failure history and checksum distrust. Pure logic on
/// top of a small persisted-free in-memory state (mirrors re-learn after a
/// relaunch, which is acceptable and keeps the surface small).
public actor MirrorIntelligence {

    public struct MirrorRecord: Sendable, Equatable {
        public var index: Int
        public var url: URL
        public var successCount: Int = 0
        public var failureCount: Int = 0
        public var checksumMismatches: Int = 0
        public var lastLatency: TimeInterval?
        public var lastThroughput: Double?
        public var lastSuccessAt: Date?
        public var lastFailureAt: Date?
        public var isDistrusted: Bool = false
        public var score: Double = 1.0
    }

    public struct FailurePolicy: Sendable {
        /// Consecutive failures before a mirror is deprioritized.
        public var consecutiveFailureThreshold: Int
        /// Checksum mismatches before a mirror is distrusted entirely.
        public var checksumDistrustThreshold: Int
        public init(consecutiveFailureThreshold: Int = 2, checksumDistrustThreshold: Int = 3) {
            self.consecutiveFailureThreshold = consecutiveFailureThreshold
            self.checksumDistrustThreshold = checksumDistrustThreshold
        }
    }

    private var records: [MirrorRecord]
    private let policy: FailurePolicy

    public init(initialURLs: [URL], policy: FailurePolicy = FailurePolicy()) {
        self.records = initialURLs.enumerated().map { index, url in
            MirrorRecord(index: index, url: url)
        }
        self.policy = policy
    }

    public func updateMirrors(_ urls: [URL]) {
        records = urls.enumerated().map { index, url in
            if let existing = records.first(where: { $0.index == index }) {
                var copy = existing
                copy.url = url
                copy.index = index
                return copy
            }
            return MirrorRecord(index: index, url: url)
        }
    }

    public func recordSuccess(index: Int, latency: TimeInterval? = nil, throughput: Double? = nil, at date: Date = Date()) {
        guard records.indices.contains(index) else { return }
        var record = records[index]
        record.successCount += 1
        record.lastLatency = latency ?? record.lastLatency
        record.lastThroughput = throughput ?? record.lastThroughput
        record.lastSuccessAt = date
        if let previous = record.lastFailureAt, date.timeIntervalSince(previous) > 300 {
            record.failureCount = 0
        }
        records[index] = record
        recomputeScores()
    }

    public func recordFailure(index: Int, at date: Date = Date()) {
        guard records.indices.contains(index) else { return }
        var record = records[index]
        record.failureCount += 1
        record.lastFailureAt = date
        if record.failureCount >= policy.consecutiveFailureThreshold {
            record.score *= 0.4
        }
        records[index] = record
        recomputeScores()
    }

    public func recordChecksumMismatch(index: Int) {
        guard records.indices.contains(index) else { return }
        var record = records[index]
        record.checksumMismatches += 1
        if record.checksumMismatches >= policy.checksumDistrustThreshold {
            record.isDistrusted = true
            record.score = 0
        }
        records[index] = record
        recomputeScores()
    }

    /// Index of the best mirror for a new attempt. Falls back to the given
    /// index when nothing better exists. Never returns a distrusted mirror
    /// while a trusted alternative remains.
    public func bestMirrorIndex(excluding: Set<Int> = []) -> Int? {
        let candidates = records.filter { !$0.isDistrusted && !excluding.contains($0.index) }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            let lhsLatency = lhs.lastLatency ?? .greatestFiniteMagnitude
            let rhsLatency = rhs.lastLatency ?? .greatestFiniteMagnitude
            return lhsLatency > rhsLatency
        }?.index
    }

    public func record(for index: Int) -> MirrorRecord? {
        guard records.indices.contains(index) else { return nil }
        return records[index]
    }

    public func allRecords() -> [MirrorRecord] {
        records
    }

    private func recomputeScores() {
        for index in records.indices {
            var record = records[index]
            guard !record.isDistrusted else {
                record.score = 0
                records[index] = record
                continue
            }
            var score = 1.0
            let total = Double(record.successCount + record.failureCount)
            if total > 0 {
                score *= Double(record.successCount) / total
            }
            if let latency = record.lastLatency {
                score *= max(0.1, 1.0 - latency / 10.0)
            }
            if let throughput = record.lastThroughput, throughput > 0 {
                score *= min(1.5, throughput / 2_000_000)
            }
            if record.failureCount >= policy.consecutiveFailureThreshold {
                score *= 0.4
            }
            record.score = max(0, min(2.0, score))
            records[index] = record
        }
    }
}