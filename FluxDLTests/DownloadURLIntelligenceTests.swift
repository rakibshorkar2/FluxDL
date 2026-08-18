import XCTest
@testable import FluxDL

final class DownloadURLIntelligenceTests: XCTestCase {

    // MARK: - Header parsing

    func testNormalizedHeadersAreCaseInsensitive() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/f")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Length": "12345", "ACCEPT-RANGES": "bytes", "ETag": "\"abc\""]
        )!
        let headers = DownloadURLIntelligence.normalizedHeaders(from: response)
        XCTAssertEqual(headers["content-length"], "12345")
        XCTAssertEqual(headers["accept-ranges"], "bytes")
        XCTAssertEqual(headers["etag"], "\"abc\"")
    }

    func testParseContentLengthToleratesFormatting() {
        XCTAssertEqual(DownloadURLIntelligence.parseContentLength("12345"), 12345)
        XCTAssertEqual(DownloadURLIntelligence.parseContentLength("12,345"), 12345)
        XCTAssertEqual(DownloadURLIntelligence.parseContentLength(" 678 "), 678)
        XCTAssertNil(DownloadURLIntelligence.parseContentLength("unknown"))
        XCTAssertNil(DownloadURLIntelligence.parseContentLength(nil))
    }

    func testParseAcceptsRanges() {
        XCTAssertTrue(DownloadURLIntelligence.parseAcceptsRanges("bytes"))
        XCTAssertTrue(DownloadURLIntelligence.parseAcceptsRanges("none, bytes"))
        XCTAssertFalse(DownloadURLIntelligence.parseAcceptsRanges("none"))
        XCTAssertFalse(DownloadURLIntelligence.parseAcceptsRanges(nil))
    }

    // MARK: - Probe result building

    func testProbeResultExtractsAllFields() {
        let url = URL(string: "https://cdn.example.com/path/file.zip")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Length": "4096",
                "Content-Type": "application/zip",
                "Accept-Ranges": "bytes",
                "ETag": "\"v2\"",
                "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT",
                "Server": "nginx",
                "Content-Disposition": "attachment; filename=\"renamed.zip\""
            ]
        )!
        let probe = DownloadURLIntelligence.probeResult(from: response, finalURL: url)
        XCTAssertEqual(probe.httpStatus, 206)
        XCTAssertEqual(probe.contentLength, 4096)
        XCTAssertEqual(probe.mimeType, "application/zip")
        XCTAssertTrue(probe.acceptsRanges)
        XCTAssertEqual(probe.etag, "\"v2\"")
        XCTAssertEqual(probe.lastModified, "Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertEqual(probe.serverName, "nginx")
        XCTAssertEqual(probe.filename, "renamed.zip", "Content-Disposition wins over the URL path")
        XCTAssertTrue(probe.isHTTP2)
        XCTAssertEqual(probe.headers["content-type"], "application/zip")
    }

    func testProbeFilenameFallsBackToURL() {
        let url = URL(string: "https://example.com/downloads/archive.tar.gz")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        let probe = DownloadURLIntelligence.probeResult(from: response, finalURL: url)
        XCTAssertEqual(probe.filename, "archive.tar.gz")
    }

    // MARK: - Expiration intelligence

    func testExpirationRiskFromSignedQuery() {
        let signed = URL(string: "https://s3.amazonaws.com/bucket/file.zip?X-Amz-Signature=abc&X-Amz-Credential=xyz&X-Amz-Expires=3600")!
        XCTAssertEqual(DownloadExpirationRisk.from(url: signed), .likelyExpiring)

        let sas = URL(string: "https://account.blob.core.windows.net/c/f?sp=r&st=2024-01-01&se=2024-02-01&sv=2020&sig=abc")!
        XCTAssertEqual(DownloadExpirationRisk.from(url: sas), .likelyExpiring)

        let plain = URL(string: "https://example.com/file.zip")!
        XCTAssertEqual(DownloadExpirationRisk.from(url: plain), .unknown)
    }

    // MARK: - Resume validation

    func testResumeValidationConsistent() {
        let probe = DownloadProbeResult(etag: "\"v1\"", lastModified: "Wed, 21 Oct 2015", contentLength: 100)
        let result = DownloadURLIntelligence.resumeValidation(
            storedETag: "\"v1\"",
            storedLastModified: "Wed, 21 Oct 2015",
            storedLength: 100,
            probe: probe
        )
        XCTAssertEqual(result, .consistent)
    }

    func testResumeValidationDetectsChangedETag() {
        let probe = DownloadProbeResult(etag: "\"v2\"", lastModified: "Wed, 21 Oct 2015", contentLength: 100)
        let result = DownloadURLIntelligence.resumeValidation(
            storedETag: "\"v1\"",
            storedLastModified: "Wed, 21 Oct 2015",
            storedLength: 100,
            probe: probe
        )
        XCTAssertEqual(result, .changedETag)
    }

    func testResumeValidationDetectsShrunkServerFile() {
        let probe = DownloadProbeResult(etag: "\"v1\"", lastModified: "Wed, 21 Oct 2015", contentLength: 40)
        let result = DownloadURLIntelligence.resumeValidation(
            storedETag: "\"v1\"",
            storedLastModified: "Wed, 21 Oct 2015",
            storedLength: 100,
            probe: probe
        )
        XCTAssertEqual(result, .serverShrunk)
    }

    func testResumeValidationIgnoresMissingMarkers() {
        let probe = DownloadProbeResult(contentLength: 100)
        let result = DownloadURLIntelligence.resumeValidation(
            storedETag: nil,
            storedLastModified: nil,
            storedLength: 100,
            probe: probe
        )
        XCTAssertEqual(result, .consistent)
    }

    // MARK: - Content-Range parsing

    func testParseContentRange() {
        let parsed = SegmentedTransferCoordinator.parseContentRange("bytes 100-199/5000")
        XCTAssertEqual(parsed?.start, 100)
        XCTAssertEqual(parsed?.end, 199)
        XCTAssertEqual(parsed?.total, 5000)
    }

    func testParseContentRangeToleratesMissingTotal() {
        let parsed = SegmentedTransferCoordinator.parseContentRange("bytes 0-9/*")
        XCTAssertEqual(parsed?.start, 0)
        XCTAssertEqual(parsed?.end, 9)
        XCTAssertEqual(parsed?.total, 0)
    }

    func testParseContentRangeRejectsMalformed() {
        XCTAssertNil(SegmentedTransferCoordinator.parseContentRange(nil))
        XCTAssertNil(SegmentedTransferCoordinator.parseContentRange("bytes 10-5/100"))
        XCTAssertNil(SegmentedTransferCoordinator.parseContentRange("0-99/100"))
    }
}
