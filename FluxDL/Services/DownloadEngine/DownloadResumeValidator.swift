import Foundation

// MARK: - Intelligent resume

/// Decides whether a download with existing partial data may continue from
/// where it stopped, and what to do when the server refuses the continuation
/// (HTTP 416). Pure logic — network-free and unit-testable.
public enum DownloadResumeValidator {

    public enum ResumeDecision: Equatable, Sendable {
        /// Safe to continue from the stored offset.
        case resumeNormally(offset: Int64)
        /// Partial data is unusable; start over with the normal engine.
        case restartNormally
        /// Partial data is unusable; start over segmented when eligible.
        case restartSegmented(connectionCount: Int)
        /// Server range metadata is missing/inconsistent — continue with a
        /// plain (non-range) download, discarding stored offsets.
        case downgradeToNormal
        /// File changed server-side; keep partial bytes only if ranges still
        /// match, otherwise restart. Caller resolves via `resolveAfter416`.
        case revalidate
        /// The URL now requires authentication or points at something the
        /// server rejects; surface as failure with a clear message.
        case needsAttention(message: String)
    }

    public struct Input: Sendable {
        public let storedETag: String?
        public let storedLastModified: String?
        public let storedLength: Int64?
        public let existingBytes: Int64
        public let probe: DownloadProbeResult?
        public let segmentedEligible: Bool
        public let proxiedRouteActive: Bool

        public init(
            storedETag: String?,
            storedLastModified: String?,
            storedLength: Int64?,
            existingBytes: Int64,
            probe: DownloadProbeResult?,
            segmentedEligible: Bool,
            proxiedRouteActive: Bool
        ) {
            self.storedETag = storedETag
            self.storedLastModified = storedLastModified
            self.storedLength = storedLength
            self.existingBytes = existingBytes
            self.probe = probe
            self.segmentedEligible = segmentedEligible
            self.proxiedRouteActive = proxiedRouteActive
        }
    }

    /// Core decision: can `existingBytes` of partial data be resumed safely?
    public static func decide(_ input: Input) -> ResumeDecision {
        guard input.existingBytes > 0 else {
            // Nothing to resume — pick segmented when eligible.
            if input.segmentedEligible, !input.proxiedRouteActive,
               let probe = input.probe, probe.acceptsRanges,
               let length = probe.contentLength, length > 0 {
                let connections = DownloadSegmentMap.initialConnectionCount(totalBytes: length)
                if connections > 1 {
                    return .restartSegmented(connectionCount: connections)
                }
            }
            return .restartNormally
        }

        guard let probe = input.probe else {
            // Unknown server state: never guess with a ranged resume.
            return .downgradeToNormal
        }

        if let status = probe.httpStatus {
            switch status {
            case 401, 403:
                return .needsAttention(message: "HTTP \(status) — URL may require authentication or have expired")
            case 404, 410:
                return .needsAttention(message: "HTTP \(status) — file no longer exists")
            case 408, 429, 500, 502, 503, 504:
                // Transient: keep partial data, retry later via the retry engine.
                return .resumeNormally(offset: input.existingBytes)
            case 416:
                return .revalidate
            default:
                if !(200...299).contains(status) {
                    return .needsAttention(message: "HTTP \(status)")
                }
            }
        }

        // Identity markers: continuation is only safe when the server file
        // still matches the one that produced our partial bytes.
        let consistency = DownloadURLIntelligence.resumeValidation(
            storedETag: input.storedETag,
            storedLastModified: input.storedLastModified,
            storedLength: input.storedLength,
            probe: probe
        )
        switch consistency {
        case .changedETag, .changedLastModified, .serverShrunk:
            return .restartNormally
        case .consistent:
            break
        }

        if !probe.acceptsRanges {
            return .downgradeToNormal
        }
        if let length = probe.contentLength, length <= input.existingBytes {
            // We already have the whole file.
            return .resumeNormally(offset: input.existingBytes)
        }
        return .resumeNormally(offset: input.existingBytes)
    }

    /// Resolves a 416 after re-probing: the server file is now shorter than
    /// our local partial data. Returns the maximum usable byte count.
    public static func resolveAfter416(serverLength: Int64?, existingBytes: Int64) -> Int64 {
        guard let serverLength, serverLength > 0 else { return 0 }
        return min(serverLength, max(existingBytes, 0))
    }
}
