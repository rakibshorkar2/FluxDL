import XCTest
@testable import FluxDL

final class DownloadIntegrityTests: XCTestCase {

    private let taskID = UUID()

    // MARK: - Resume validator

    private func makeProbe(
        status: Int = 200,
        length: Int64? = 1_000_000,
        acceptsRanges: Bool = true,
        etag: String? = "\"v1\"",
        lastModified: String? = "Wed, 21 Oct 2015"
    ) -> DownloadProbeResult {
        DownloadProbeResult(
            httpStatus: status,
            contentLength: length,
            acceptsRanges: acceptsRanges,
            etag: etag,
            lastModified: lastModified
        )
    }

    func testResumeValidatorAllowsSafeRangeResume() {
        let decision = DownloadResumeValidator.decide(DownloadResumeValidator.Input(
            storedETag: "\"v1\"",
            storedLastModified: "Wed, 21 Oct 2015",
            storedLength: 1_000_000,
            existingBytes: 500_000,
            probe: makeProbe(),
            segmentedEligible: true,
            proxiedRouteActive: false
        ))
        XCTAssertEqual(decision, .resumeNormally(offset: 500_000))
    }

    func testResumeValidatorRestartsOnChangedETag() {
        let decision = DownloadResumeValidator.decide(DownloadResumeValidator.Input(
            storedETag: "\"v1\"",
            storedLastModified: nil,
            storedLength: 1_000_000,
            existingBytes: 500_000,
            probe: makeProbe(etag: "\"v2\""),
            segmentedEligible: true,
            proxiedRouteActive: false
        ))
        XCTAssertEqual(decision, .restartNormally)
    }

    func testResumeValidatorRestartsOnShrunkServerFile() {
        let decision = DownloadResumeValidator.decide(DownloadResumeValidator.Input(
            storedETag: "\"v1\"",
            storedLastModified: nil,
            storedLength: 1_000_000,
            existingBytes: 500_000,
            probe: makeProbe(length: 300_000),
            segmentedEligible: true,
            proxiedRouteActive: false
        ))
        XCTAssertEqual(decision, .restartNormally)
    }

    func testResumeValidatorDowngradesWhenRangesUnsupported() {
        let decision = DownloadResumeValidator.decide(DownloadResumeValidator.Input(
            storedETag: "\"v1\"",
            storedLastModified: nil,
            storedLength: 1_000_000,
            existingBytes: 500_000,
            probe: makeProbe(acceptsRanges: false),
            segmentedEligible: true,
            proxiedRouteActive: false
        ))
        XCTAssertEqual(decision, .downgradeToNormal)
    }

    func testResumeValidatorNeedsAttentionOnAuth() {
        let decision = DownloadResumeValidator.decide(DownloadResumeValidator.Input(
            storedETag: nil,
            storedLastModified: nil,
            storedLength: nil,
            existingBytes: 10,
            probe: makeProbe(status: 403),
            segmentedEligible: true,
            proxiedRouteActive: false
        ))
        if case .needsAttention = decision {
            // expected
        } else {
            XCTFail("403 must need attention")
        }
    }

    func testResumeValidatorKeepsPartialBytesOnTransientStatus() {
        let decision = DownloadResumeValidator.decide(DownloadResumeValidator.Input(
            storedETag: nil,
            storedLastModified: nil,
            storedLength: nil,
            existingBytes: 10,
            probe: makeProbe(status: 503),
            segmentedEligible: true,
            proxiedRouteActive: false
        ))
        XCTAssertEqual(decision, .resumeNormally(offset: 10))
    }

    func testResumeValidator416TriggersRevalidate() {
        let decision = DownloadResumeValidator.decide(DownloadResumeValidator.Input(
            storedETag: nil,
            storedLastModified: nil,
            storedLength: nil,
            existingBytes: 10,
            probe: makeProbe(status: 416),
            segmentedEligible: true,
            proxiedRouteActive: false
        ))
        XCTAssertEqual(decision, .revalidate)
    }

    func testResolveAfter416ClampsToServerLength() {
        XCTAssertEqual(DownloadResumeValidator.resolveAfter416(serverLength: 500, existingBytes: 900), 500)
        XCTAssertEqual(DownloadResumeValidator.resolveAfter416(serverLength: nil, existingBytes: 900), 0)
        XCTAssertEqual(DownloadResumeValidator.resolveAfter416(serverLength: 0, existingBytes: 900), 0)
    }

    // MARK: - Strategy engine

    func testStrategyRecommendsSegmentedForLargeRangeFile() {
        let url = URL(string: "https://example.com/big.zip")!
        let probe = DownloadProbeResult(httpStatus: 200, contentLength: 1 * 1024 * 1024 * 1024, acceptsRanges: true)
        let recommendation = DownloadStrategyEngine.recommend(
            probe: probe,
            url: url,
            existingBytes: 0,
            segmentedEnabled: true,
            proxiedRouteActive: false
        )
        XCTAssertEqual(recommendation.strategy, .segmented)
        XCTAssertEqual(recommendation.connectionCount, 4)
    }

    func testStrategyRefusesSegmentedWithoutRangeSupport() {
        let url = URL(string: "https://example.com/big.zip")!
        let probe = DownloadProbeResult(httpStatus: 200, contentLength: 1 * 1024 * 1024 * 1024, acceptsRanges: false)
        let recommendation = DownloadStrategyEngine.recommend(
            probe: probe,
            url: url,
            existingBytes: 0,
            segmentedEnabled: true,
            proxiedRouteActive: false
        )
        XCTAssertNotEqual(recommendation.strategy, .segmented)
    }

    func testStrategyRefusesSegmentedUnderProxyRoute() {
        let url = URL(string: "https://example.com/big.zip")!
        let probe = DownloadProbeResult(httpStatus: 200, contentLength: 1 * 1024 * 1024 * 1024, acceptsRanges: true)
        let recommendation = DownloadStrategyEngine.recommend(
            probe: probe,
            url: url,
            existingBytes: 0,
            segmentedEnabled: true,
            proxiedRouteActive: true
        )
        XCTAssertNotEqual(recommendation.strategy, .segmented, "fail closed under proxy")
    }

    func testStrategyRefusesSegmentedWhenDisabled() {
        let url = URL(string: "https://example.com/big.zip")!
        let probe = DownloadProbeResult(httpStatus: 200, contentLength: 1 * 1024 * 1024 * 1024, acceptsRanges: true)
        let recommendation = DownloadStrategyEngine.recommend(
            probe: probe,
            url: url,
            existingBytes: 0,
            segmentedEnabled: false,
            proxiedRouteActive: false
        )
        XCTAssertNotEqual(recommendation.strategy, .segmented)
    }

    func testStrategyKeepsNormalWithoutMetadata() {
        let url = URL(string: "https://example.com/unknown.bin")!
        let recommendation = DownloadStrategyEngine.recommend(
            probe: nil,
            url: url,
            existingBytes: 0,
            segmentedEnabled: true,
            proxiedRouteActive: false
        )
        XCTAssertEqual(recommendation.strategy, .normal)
    }

    func testStrategyDoesNotSegmentSmallFiles() {
        let url = URL(string: "https://example.com/small.zip")!
        let probe = DownloadProbeResult(httpStatus: 200, contentLength: 10 * 1024 * 1024, acceptsRanges: true)
        let recommendation = DownloadStrategyEngine.recommend(
            probe: probe,
            url: url,
            existingBytes: 0,
            segmentedEnabled: true,
            proxiedRouteActive: false
        )
        XCTAssertNotEqual(recommendation.strategy, .segmented)
    }

    // MARK: - Segment file assembler (real temp files)

    func testAssembleConcatenatesSegmentsInOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxDLAssemblerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let segments = [
            DownloadSegment(taskID: taskID, byteStart: 0, byteEnd: 2, downloadedBytes: 3, state: .completed),
            DownloadSegment(taskID: taskID, byteStart: 3, byteEnd: 6, downloadedBytes: 4, state: .completed),
            DownloadSegment(taskID: taskID, byteStart: 7, byteEnd: 9, downloadedBytes: 3, state: .completed)
        ]
        let partData: [String: Data] = [
            segments[0].segmentID.uuidString: Data([0x01, 0x02, 0x03]),
            segments[1].segmentID.uuidString: Data([0x04, 0x05, 0x06, 0x07]),
            segments[2].segmentID.uuidString: Data([0x08, 0x09, 0x0A])
        ]
        for segment in segments {
            try partData[segment.segmentID.uuidString]!.write(to: dir.appendingPathComponent(segment.segmentID.uuidString + ".part"))
        }

        let output = dir.appendingPathComponent("assembled.tmp")
        try SegmentFileAssembler.assemble(segments: segments, partDirectory: dir, outputURL: output)
        let assembled = try Data(contentsOf: output)
        XCTAssertEqual(assembled, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]))

        let destination = dir.appendingPathComponent("final.bin")
        try SegmentFileAssembler.finalize(assembledURL: output, destinationURL: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), assembled)

        try FileManager.default.removeItem(at: dir)
    }

    func testAssembleFailsOnMissingSegmentFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxDLAssemblerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let segments = [
            DownloadSegment(taskID: taskID, byteStart: 0, byteEnd: 2, downloadedBytes: 3, state: .completed),
            DownloadSegment(taskID: taskID, byteStart: 3, byteEnd: 6, downloadedBytes: 4, state: .completed)
        ]
        try Data([0x01, 0x02, 0x03]).write(to: dir.appendingPathComponent(segments[0].segmentID.uuidString + ".part"))

        let output = dir.appendingPathComponent("assembled.tmp")
        XCTAssertThrowsError(try SegmentFileAssembler.assemble(segments: segments, partDirectory: dir, outputURL: output))
        try FileManager.default.removeItem(at: dir)
    }

    func testAssembleFailsOnShortSegment() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxDLAssemblerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let segment = DownloadSegment(taskID: taskID, byteStart: 0, byteEnd: 4, downloadedBytes: 5, state: .completed)
        try Data([0x01]).write(to: dir.appendingPathComponent(segment.segmentID.uuidString + ".part"))

        let output = dir.appendingPathComponent("assembled.tmp")
        XCTAssertThrowsError(try SegmentFileAssembler.assemble(segments: [segment], partDirectory: dir, outputURL: output))
        try FileManager.default.removeItem(at: dir)
    }

    func testAssemblerPlanValidationCatchesGaps() {
        let segments = [
            DownloadSegment(taskID: taskID, byteStart: 0, byteEnd: 2),
            DownloadSegment(taskID: taskID, byteStart: 5, byteEnd: 7) // gap at 3-4
        ]
        if case .failure = SegmentFileAssembler.Plan.validate(segments: segments, expectedSize: 8) {
            // expected: gap detected
        } else {
            XCTFail("gap must be detected")
        }
    }

    func testAssemblerPlanValidationAcceptsFullCoverage() throws {
        let segments = [
            DownloadSegment(taskID: taskID, byteStart: 0, byteEnd: 2),
            DownloadSegment(taskID: taskID, byteStart: 3, byteEnd: 6)
        ]
        let result = SegmentFileAssembler.Plan.validate(segments: segments, expectedSize: 7)
        if case .failure = result {
            XCTFail("full coverage must validate")
        }
    }
}
