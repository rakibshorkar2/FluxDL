import XCTest
@testable import FluxDL

final class MirrorIntelligenceTests: XCTestCase {

    private let mirrorURLs = [
        URL(string: "https://mirror-a.example.com/f.bin")!,
        URL(string: "https://mirror-b.example.com/f.bin")!,
        URL(string: "https://mirror-c.example.com/f.bin")!
    ]

    func testInitialBestMirrorIsFirst() async {
        let intelligence = MirrorIntelligence(initialURLs: mirrorURLs)
        let best = await intelligence.bestMirrorIndex()
        XCTAssertEqual(best, 0)
    }

    func testFailureDeprioritizesMirror() async {
        let intelligence = MirrorIntelligence(initialURLs: mirrorURLs)
        await intelligence.recordFailure(index: 0)
        await intelligence.recordFailure(index: 0) // threshold reached
        let best = await intelligence.bestMirrorIndex()
        XCTAssertNotEqual(best, 0, "a mirror at the failure threshold must not be picked first")
    }

    func testSuccessKeepsMirrorRelevant() async {
        let intelligence = MirrorIntelligence(initialURLs: mirrorURLs)
        await intelligence.recordSuccess(index: 1, latency: 0.05, throughput: 8_000_000)
        let best = await intelligence.bestMirrorIndex()
        XCTAssertEqual(best, 1, "fast, successful mirror should score highest")
    }

    func testChecksumMismatchesDistrustMirror() async {
        let intelligence = MirrorIntelligence(initialURLs: mirrorURLs)
        for _ in 0..<3 {
            await intelligence.recordChecksumMismatch(index: 2)
        }
        let best = await intelligence.bestMirrorIndex()
        XCTAssertNotEqual(best, 2, "a distrusted mirror must never be chosen")
        let record = await intelligence.record(for: 2)
        XCTAssertTrue(record?.isDistrusted ?? false)
    }

    func testDistrustedMirrorIsLastResortWhenAlone() async {
        let intelligence = MirrorIntelligence(initialURLs: [mirrorURLs[0]])
        for _ in 0..<3 {
            await intelligence.recordChecksumMismatch(index: 0)
        }
        // No trusted alternative exists — must still return something rather
        // than nil (the engine surfaces the distrust to the user).
        let best = await intelligence.bestMirrorIndex()
        XCTAssertNotNil(best)
    }

    func testBestMirrorRespectsExclusions() async {
        let intelligence = MirrorIntelligence(initialURLs: mirrorURLs)
        await intelligence.recordSuccess(index: 1, latency: 0.05, throughput: 8_000_000)
        await intelligence.recordSuccess(index: 2, latency: 0.05, throughput: 8_000_000)
        let best = await intelligence.bestMirrorIndex(excluding: [1])
        XCTAssertEqual(best, 2)
    }

    func testUpdateMirrorsKeepsHistoryByIndex() async {
        let intelligence = MirrorIntelligence(initialURLs: mirrorURLs)
        await intelligence.recordSuccess(index: 0, latency: 0.1, throughput: 5_000_000)
        await intelligence.recordFailure(index: 1)

        let rotated = [
            URL(string: "https://mirror-a2.example.com/f.bin")!,
            mirrorURLs[1],
            mirrorURLs[2]
        ]
        await intelligence.updateMirrors(rotated)
        let best = await intelligence.bestMirrorIndex()
        XCTAssertEqual(best, 0, "history should carry over by index")
    }

    func testAllRecordsExposeScores() async {
        let intelligence = MirrorIntelligence(initialURLs: mirrorURLs)
        await intelligence.recordSuccess(index: 0, latency: 0.1, throughput: 6_000_000)
        let records = await intelligence.allRecords()
        XCTAssertEqual(records.count, 3)
        XCTAssertGreaterThan(records[0].score, 0)
    }
}
