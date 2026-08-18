import Foundation

// MARK: - Error classification

/// Classifies a failure so the engine can react correctly instead of blindly
/// retrying. Pure logic, fully unit-testable.
public enum DownloadErrorClassifier {

    public enum FailureKind: Equatable, Sendable {
        /// Never retry — retrying is pointless (404, invalid URL, disk full…).
        case permanent(message: String?)
        /// Retry after the given delay (seconds), e.g. 429 with Retry-After.
        case retryable(after: TimeInterval, message: String?)
        /// Retry with exponential backoff (5xx, timeouts, network flaps).
        case backoff(message: String?)
        /// The server file changed / range no longer applies — revalidate
        /// identity markers before continuing.
        case revalidate(message: String?)
        /// Surface to the user and stop (auth, expiry).
        case needsAttention(message: String?)
    }

    /// HTTP status → reaction. Exhaustive table used by both the retry engine
    /// and the segmented coordinator.
    public static func classify(httpStatus: Int, retryAfterHeader: String? = nil) -> FailureKind {
        switch httpStatus {
        case 200...299:
            return .backoff(message: "HTTP \(httpStatus) — unexpected success status on failure path")
        case 301, 302, 303, 307, 308:
            return .retryable(after: 0, message: "HTTP \(httpStatus) — redirect")
        case 304:
            return .permanent(message: "HTTP 304 — not modified, nothing to download")
        case 400:
            return .permanent(message: "HTTP 400 — bad request")
        case 401, 403:
            return .needsAttention(message: "HTTP \(httpStatus) — authentication required or access denied")
        case 404, 405, 406, 410, 451:
            return .permanent(message: "HTTP \(httpStatus) — resource unavailable")
        case 408:
            return .retryable(after: 2, message: "HTTP 408 — request timeout")
        case 416:
            return .revalidate(message: "HTTP 416 — range not satisfiable")
        case 429:
            return .retryable(after: Self.retryAfterSeconds(from: retryAfterHeader, default: 30), message: "HTTP 429 — too many requests")
        case 500, 502, 503, 504:
            return .backoff(message: "HTTP \(httpStatus) — server error")
        case 501:
            return .permanent(message: "HTTP 501 — not implemented (range likely unsupported)")
        case 505...599:
            return .backoff(message: "HTTP \(httpStatus)")
        default:
            return .retryable(after: 2, message: "HTTP \(httpStatus)")
        }
    }

    /// Maps Foundation errors to failure kinds. `domain`/`code` pairs follow
    /// NSURLErrorDomain / NSPOSIXErrorDomain values.
    public static func classify(domain: String?, code: Int, underlyingDescription: String? = nil) -> FailureKind {
        let message = underlyingDescription ?? "\(domain ?? "Unknown").\(code)"
        switch domain {
        case NSURLErrorDomain:
            switch code {
            case NSURLErrorCancelled:
                return .permanent(message: "Cancelled")
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
                return .permanent(message: "Invalid URL")
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed,
                 NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                 NSURLErrorResourceUnavailable, NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot:
                return .backoff(message: message)
            case NSURLErrorUserAuthenticationRequired:
                return .needsAttention(message: "Authentication required")
            case NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory:
                return .permanent(message: message)
            case NSURLErrorRequestBodyStreamExhausted:
                return .revalidate(message: message)
            default:
                return .retryable(after: 2, message: message)
            }
        case NSPOSIXErrorDomain:
            let errnoCode = Int32(code)
            if errnoCode == ENOSPC || errnoCode == EDQUOT {
                return .permanent(message: "Disk full")
            }
            return .retryable(after: 2, message: message)
        case NSCocoaErrorDomain where code == NSFileWriteOutOfSpaceError:
            return .permanent(message: "Disk full")
        case NSCocoaErrorDomain where code == NSFileWriteVolumeReadOnlyError:
            return .permanent(message: "Storage is read-only")
        default:
            return .retryable(after: 2, message: message)
        }
    }

    /// Parses a Retry-After header (seconds or HTTP-date).
    public static func retryAfterSeconds(from header: String?, default defaultDelay: TimeInterval) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return defaultDelay
        }
        if let seconds = TimeInterval(header), seconds >= 0 {
            return min(seconds, 3600)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            return min(max(date.timeIntervalSinceNow, 0), 3600)
        }
        return defaultDelay
    }
}

// MARK: - Backoff schedule

/// Deterministic backoff: 1, 2, 4, 8, 16, 30, 60 seconds, then capped at 60.
/// Optional ±20% jitter keeps synchronized retries from stampeding servers.
public enum DownloadBackoffSchedule {

    public static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 60]

    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 1 }
        return delays[min(attempt - 1, delays.count - 1)]
    }

    /// Jittered delay, reproducible for tests by passing a fixed `jitterValue`.
    /// `jitterValue` must be in 0...1 and defaults to a random value.
    public static func jitteredDelay(forAttempt attempt: Int, jitterValue: Double = Double.random(in: 0...1)) -> TimeInterval {
        let base = delay(forAttempt: attempt)
        let bounded = min(max(jitterValue, 0), 1)
        let factor = 0.8 + (bounded * 0.4)
        return base * factor
    }
}

// MARK: - Retry engine

/// Applies the classification table with per-task budgets, consecutive-failure
/// limits, and a "needs attention" escape hatch. Pure logic.
public struct DownloadRetryEngine: Sendable {

    public struct Budget: Equatable, Sendable {
        public var totalRetries: Int
        public var consecutiveFailures: Int
        public var perSegmentRetries: Int
        public var mirrorSwitches: Int

        public init(totalRetries: Int = 10, consecutiveFailures: Int = 3, perSegmentRetries: Int = 3, mirrorSwitches: Int = 2) {
            self.totalRetries = totalRetries
            self.consecutiveFailures = consecutiveFailures
            self.perSegmentRetries = perSegmentRetries
            self.mirrorSwitches = mirrorSwitches
        }

        public var exhausted: Bool { totalRetries <= 0 || consecutiveFailures <= 0 }
    }

    public enum Action: Equatable, Sendable {
        /// Give up now; classify as permanent.
        case stop
        /// Wait `delay` seconds, then try again with the same attempt number.
        case retry(delay: TimeInterval)
        /// Same as retry but also decrement the budget (used for 4xx+5xx).
        case retryCounting(delay: TimeInterval)
        /// Re-probe the server and revalidate identity markers first.
        case revalidate(delay: TimeInterval)
        /// Let the mirror intelligence pick a different source.
        case switchMirror(delay: TimeInterval)
        /// Pause the transfer and surface the message to the user.
        case needsAttention(message: String)
    }

    public struct Evaluation: Equatable, Sendable {
        public let action: Action
        public let remainingBudget: Budget
        public let attempted: Int
    }

    /// Evaluates a failure against the current budget.
    public static func evaluate(
        failure: DownloadErrorClassifier.FailureKind,
        attempted: Int,
        budget: Budget
    ) -> Evaluation {
        switch failure {
        case .permanent(let message):
            return Evaluation(
                action: .stop,
                remainingBudget: budget,
                attempted: attempted
            )
        case .needsAttention(let message):
            return Evaluation(
                action: .needsAttention(message: message ?? "Needs attention"),
                remainingBudget: budget,
                attempted: attempted
            )
        case .revalidate(let message):
            if budget.exhausted {
                return Evaluation(action: .needsAttention(message: message ?? "Range no longer valid"), remainingBudget: budget, attempted: attempted)
            }
            var next = budget
            next.totalRetries -= 1
            next.consecutiveFailures = max(0, next.consecutiveFailures - 1)
            return Evaluation(
                action: .revalidate(delay: DownloadBackoffSchedule.delay(forAttempt: attempted)),
                remainingBudget: next,
                attempted: attempted + 1
            )
        case .backoff(let message):
            if budget.exhausted {
                return Evaluation(action: .needsAttention(message: message ?? "Retry budget exhausted"), remainingBudget: budget, attempted: attempted)
            }
            var next = budget
            next.totalRetries -= 1
            next.consecutiveFailures = max(0, next.consecutiveFailures - 1)
            if next.consecutiveFailures == 0 {
                return Evaluation(
                    action: .needsAttention(message: message ?? "Repeated failures"),
                    remainingBudget: next,
                    attempted: attempted + 1
                )
            }
            return Evaluation(
                action: .retryCounting(delay: DownloadBackoffSchedule.jitteredDelay(forAttempt: attempted)),
                remainingBudget: next,
                attempted: attempted + 1
            )
        case .retryable(let after, let message):
            let delay = max(after, DownloadBackoffSchedule.delay(forAttempt: attempted))
            return Evaluation(
                action: .retry(delay: delay),
                remainingBudget: budget,
                attempted: attempted + 1
            )
        }
    }
}
