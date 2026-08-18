import XCTest
@testable import FluxDL

final class DownloadRetryEngineTests: XCTestCase {

    // MARK: - HTTP classification

    func testClassifyPermanentStatuses() {
        for status in [304, 400, 404, 405, 406, 410, 451] {
            let kind = DownloadErrorClassifier.classify(httpStatus: status)
            XCTAssertEqual(kind, .permanent(message: nil), "HTTP \(status) must be permanent")
        }
    }

    func testClassifyNeedsAttentionStatuses() {
        for status in [401, 403] {
            let kind = DownloadErrorClassifier.classify(httpStatus: status)
            XCTAssertEqual(kind, .needsAttention(message: nil), "HTTP \(status) must need attention")
        }
    }

    func testClassifyRetryableStatuses() {
        let retry = DownloadErrorClassifier.classify(httpStatus: 408)
        XCTAssertEqual(retry, .retryable(after: 2, message: nil))

        let limited = DownloadErrorClassifier.classify(httpStatus: 429, retryAfterHeader: "120")
        XCTAssertEqual(limited, .retryable(after: 120, message: nil))
    }

    func testClassifyBackoffStatuses() {
        for status in [500, 502, 503, 504] {
            let kind = DownloadErrorClassifier.classify(httpStatus: status)
            XCTAssertEqual(kind, .backoff(message: nil), "HTTP \(status) must use backoff")
        }
    }

    func testClassifyRangeUnsupported() {
        XCTAssertEqual(DownloadErrorClassifier.classify(httpStatus: 501), .permanent(message: nil))
    }

    func testClassify416AsRevalidate() {
        XCTAssertEqual(DownloadErrorClassifier.classify(httpStatus: 416), .revalidate(message: nil))
    }

    func testClassifyURLErrors() {
        XCTAssertEqual(
            DownloadErrorClassifier.classify(domain: NSURLErrorDomain, code: NSURLErrorBadURL),
            .permanent(message: "Invalid URL")
        )
        XCTAssertEqual(
            DownloadErrorClassifier.classify(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            .backoff(message: nil)
        )
        XCTAssertEqual(
            DownloadErrorClassifier.classify(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            .permanent(message: "Disk full")
        )
    }

    func testRetryAfterParsingSeconds() {
        XCTAssertEqual(DownloadErrorClassifier.retryAfterSeconds(from: "45", default: 30), 45)
        XCTAssertEqual(DownloadErrorClassifier.retryAfterSeconds(from: " 10 ", default: 30), 10)
        XCTAssertEqual(DownloadErrorClassifier.retryAfterSeconds(from: nil, default: 30), 30)
        XCTAssertEqual(DownloadErrorClassifier.retryAfterSeconds(from: "garbage", default: 30), 30)
    }

    // MARK: - Backoff schedule

    func testBackoffDelaysSequence() {
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 1), 1)
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 2), 2)
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 3), 4)
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 4), 8)
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 5), 16)
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 6), 30)
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 7), 60)
        XCTAssertEqual(DownloadBackoffSchedule.delay(forAttempt: 99), 60, "capped at 60s")
    }

    func testJitteredDelayStaysWithinBounds() {
        for attempt in 1...7 {
            let jittered = DownloadBackoffSchedule.jitteredDelay(forAttempt: attempt, jitterValue: 0)
            XCTAssertEqual(jittered, DownloadBackoffSchedule.delay(forAttempt: attempt) * 0.8, accuracy: 0.001)
            let high = DownloadBackoffSchedule.jitteredDelay(forAttempt: attempt, jitterValue: 1)
            XCTAssertEqual(high, DownloadBackoffSchedule.delay(forAttempt: attempt) * 1.2, accuracy: 0.001)
        }
    }

    // MARK: - Budget & actions

    func testPermanentFailureStopsImmediately() {
        let result = DownloadRetryEngine.evaluate(
            failure: .permanent(message: "gone"),
            attempted: 1,
            budget: DownloadRetryEngine.Budget(totalRetries: 10, consecutiveFailures: 3, perSegmentRetries: 3, mirrorSwitches: 2)
        )
        XCTAssertEqual(result.action, .stop)
        XCTAssertEqual(result.remainingBudget, DownloadRetryEngine.Budget(totalRetries: 10, consecutiveFailures: 3, perSegmentRetries: 3, mirrorSwitches: 2))
    }

    func testBackoffConsumesBudget() {
        let result = DownloadRetryEngine.evaluate(
            failure: .backoff(message: nil),
            attempted: 1,
            budget: DownloadRetryEngine.Budget(totalRetries: 10, consecutiveFailures: 3, perSegmentRetries: 3, mirrorSwitches: 2)
        )
        XCTAssertEqual(result.remainingBudget.totalRetries, 9)
        XCTAssertEqual(result.remainingBudget.consecutiveFailures, 2)
        if case .retryCounting(let delay) = result.action {
            XCTAssertGreaterThanOrEqual(delay, DownloadBackoffSchedule.delay(forAttempt: 1))
        } else {
            XCTFail("expected retryCounting")
        }
    }

    func testConsecutiveFailuresExhaustionNeedsAttention() {
        let result = DownloadRetryEngine.evaluate(
            failure: .backoff(message: "flapping"),
            attempted: 1,
            budget: DownloadRetryEngine.Budget(totalRetries: 10, consecutiveFailures: 1, perSegmentRetries: 3, mirrorSwitches: 2)
        )
        XCTAssertEqual(result.action, .needsAttention(message: "Repeated failures"))
    }

    func testTotalBudgetExhaustionNeedsAttention() {
        let result = DownloadRetryEngine.evaluate(
            failure: .backoff(message: "budget gone"),
            attempted: 1,
            budget: DownloadRetryEngine.Budget(totalRetries: 0, consecutiveFailures: 3, perSegmentRetries: 3, mirrorSwitches: 2)
        )
        XCTAssertEqual(result.action, .needsAttention(message: "budget gone"))
    }

    func testRetryable429UsesServerDelayWithoutConsumingBudget() {
        let result = DownloadRetryEngine.evaluate(
            failure: .retryable(after: 120, message: nil),
            attempted: 1,
            budget: DownloadRetryEngine.Budget()
        )
        XCTAssertEqual(result.action, .retry(delay: 120))
        XCTAssertEqual(result.remainingBudget, DownloadRetryEngine.Budget(), "429 respects Retry-After without consuming the budget")
    }

    func testRevalidateConsumesBudget() {
        let result = DownloadRetryEngine.evaluate(
            failure: .revalidate(message: nil),
            attempted: 3,
            budget: DownloadRetryEngine.Budget()
        )
        XCTAssertEqual(result.remainingBudget.totalRetries, 9)
        if case .revalidate(let delay) = result.action {
            XCTAssertEqual(delay, 4)
        } else {
            XCTFail("expected revalidate")
        }
    }
}
