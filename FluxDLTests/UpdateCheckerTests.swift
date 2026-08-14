import XCTest
@testable import FluxDL

// MARK: - Test doubles

private struct StubAppVersionService: AppVersionServiceProtocol {
    let versionString: String
    var buildString: String { "1" }
    var semanticVersion: SemanticVersion? { SemanticVersion(rawValue: versionString) }
}

private struct StubGitHubReleaseService: GitHubReleaseServiceProtocol {
    let result: Result<GitHubRelease, UpdateCheckError>

    func fetchLatestRelease(forceRefresh: Bool) async throws -> GitHubRelease {
        switch result {
        case .success(let release): return release
        case .failure(let error): throw error
        }
    }
}

// MARK: - GitHubRelease JSON fixtures

private enum ReleaseFixture {
    static func json(tag: String, assets: [[String: Any]] = []) -> Data {
        let payload: [String: Any] = [
            "url": "https://api.github.com/repos/rakibshorkar2/FluxDL/releases/1",
            "tag_name": tag,
            "name": "FluxDL \(tag)",
            "body": "What's New\n- Improved downloads",
            "html_url": "https://github.com/rakibshorkar2/FluxDL/releases/tag/\(tag)",
            "published_at": "2026-01-01T00:00:00Z",
            "assets": assets,
            "some_future_github_field": ["ignored": true],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static func ipaAsset(name: String = "FluxDL-2.0.2.ipa") -> [String: Any] {
        [
            "name": name,
            "browser_download_url": "https://github.com/rakibshorkar2/FluxDL/releases/download/v2.0.2/\(name)",
            "size": 1_234_567,
            "download_count": 42,
        ]
    }

    static func release(tag: String, assets: [[String: Any]] = []) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: json(tag: tag, assets: assets))
    }
}

// MARK: - UpdateChecker tests

final class UpdateCheckerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "fluxdl_update_cache_release")
        UserDefaults.standard.removeObject(forKey: "fluxdl_update_cache_date")
    }

    private func makeChecker(
        installed: String,
        releaseResult: Result<GitHubRelease, UpdateCheckError>
    ) -> UpdateChecker {
        UpdateChecker(
            releaseService: StubGitHubReleaseService(result: releaseResult),
            versionService: StubAppVersionService(versionString: installed)
        )
    }

    func testScenarioA_installedEqualsLatest_isUpToDate() async throws {
        let checker = makeChecker(
            installed: "2.0.1",
            releaseResult: .success(try ReleaseFixture.release(tag: "v2.0.1"))
        )
        let result = try await checker.checkForUpdates(forceRefresh: true)
        XCTAssertFalse(result.updateAvailable)
    }

    func testScenarioB_patchUpdate_isAvailable() async throws {
        let checker = makeChecker(
            installed: "2.0.1",
            releaseResult: .success(try ReleaseFixture.release(tag: "v2.0.2"))
        )
        let result = try await checker.checkForUpdates(forceRefresh: true)
        XCTAssertTrue(result.updateAvailable)
        XCTAssertEqual(result.latestRelease.version, "2.0.2")
    }

    func testScenarioC_minorUpdate_isAvailable() async throws {
        let checker = makeChecker(
            installed: "2.0.1",
            releaseResult: .success(try ReleaseFixture.release(tag: "v2.1.0"))
        )
        let result = try await checker.checkForUpdates(forceRefresh: true)
        XCTAssertTrue(result.updateAvailable)
    }

    func testScenarioD_majorUpdate_isAvailable() async throws {
        let checker = makeChecker(
            installed: "2.0.1",
            releaseResult: .success(try ReleaseFixture.release(tag: "v3.0.0"))
        )
        let result = try await checker.checkForUpdates(forceRefresh: true)
        XCTAssertTrue(result.updateAvailable)
    }

    func testScenarioE_installedNewerThanLatest_isUpToDate() async throws {
        let checker = makeChecker(
            installed: "2.0.10",
            releaseResult: .success(try ReleaseFixture.release(tag: "v2.0.9"))
        )
        let result = try await checker.checkForUpdates(forceRefresh: true)
        XCTAssertFalse(result.updateAvailable)
    }

    func testScenarioG_invalidTag_surfacesInvalidRelease() async {
        let checker = makeChecker(
            installed: "2.0.1",
            releaseResult: .success(try! ReleaseFixture.release(tag: "not-a-version"))
        )
        do {
            _ = try await checker.checkForUpdates(forceRefresh: true)
            XCTFail("Expected invalidRelease error")
        } catch UpdateCheckError.invalidRelease {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testNetworkError_surfacesAsNetwork() async {
        let checker = makeChecker(
            installed: "2.0.1",
            releaseResult: .failure(.network)
        )
        do {
            _ = try await checker.checkForUpdates(forceRefresh: true)
            XCTFail("Expected network error")
        } catch UpdateCheckError.network {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRateLimitError_surfacesAsRateLimited() async {
        let checker = makeChecker(
            installed: "2.0.1",
            releaseResult: .failure(.rateLimited)
        )
        do {
            _ = try await checker.checkForUpdates(forceRefresh: true)
            XCTFail("Expected rate limited error")
        } catch UpdateCheckError.rateLimited {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Release decoding & assets

    func testScenarioI_releaseWithIPAAsset_detectsAsset() throws {
        let release = try ReleaseFixture.release(tag: "v2.0.2", assets: [ReleaseFixture.ipaAsset()])
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "FluxDL-2.0.2.ipa")
        XCTAssertEqual(release.assets.first?.size, 1_234_567)
        XCTAssertEqual(
            release.assets.first?.downloadURL.absoluteString,
            "https://github.com/rakibshorkar2/FluxDL/releases/download/v2.0.2/FluxDL-2.0.2.ipa"
        )
        XCTAssertNotNil(release.ipaAsset)
    }

    func testScenarioJ_releaseWithoutAssets_stillValid() throws {
        let release = try ReleaseFixture.release(tag: "v2.0.2")
        XCTAssertTrue(release.assets.isEmpty)
        XCTAssertNil(release.ipaAsset)
        XCTAssertEqual(release.version, "2.0.2")
        XCTAssertEqual(
            release.releaseURL.absoluteString,
            "https://github.com/rakibshorkar2/FluxDL/releases/tag/v2.0.2"
        )
    }

    func testReleaseNotesAndMetadataDecoded() throws {
        let release = try ReleaseFixture.release(tag: "v2.0.2", assets: [ReleaseFixture.ipaAsset()])
        XCTAssertEqual(release.title, "FluxDL v2.0.2")
        XCTAssertTrue(release.releaseNotes.contains("Improved downloads"))
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.tagName, "v2.0.2")
    }

    func testCIBuildTagNormalizesToDisplayVersion() throws {
        let release = try ReleaseFixture.release(tag: "v2.0.1.456")
        XCTAssertEqual(release.version, "2.0.1")
    }

    func testReleaseNotesSanitizerStripsMarkdown() {
        let raw = "## Improvements\n- Fixed **directory navigation**\n- See [release page](https://example.com) for details"
        let text = ReleaseNotesSanitizer.plainText(raw)
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("["))
        XCTAssertTrue(text.contains("Fixed directory navigation"))
        XCTAssertTrue(text.contains("•"))
    }

    // MARK: - GitHubReleaseService over URLProtocol (network layer)

    func testService_successfulFetch_decodesRelease() async throws {
        let service = makeNetworkService { _ in
            (ReleaseFixture.json(tag: "v2.0.2", assets: [ReleaseFixture.ipaAsset()]), 200)
        }
        let release = try await service.fetchLatestRelease(forceRefresh: true)
        XCTAssertEqual(release.version, "2.0.2")
        XCTAssertEqual(release.assets.first?.name, "FluxDL-2.0.2.ipa")
    }

    func testService_malformedJSON_surfacesInvalidResponse() async {
        let service = makeNetworkService { _ in
            (Data("not json {".utf8), 200)
        }
        do {
            _ = try await service.fetchLatestRelease(forceRefresh: true)
            XCTFail("Expected invalidResponse error")
        } catch UpdateCheckError.invalidResponse {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testService_scenarioF_noInternet_surfacesNetwork() async {
        let service = makeNetworkService { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await service.fetchLatestRelease(forceRefresh: true)
            XCTFail("Expected network error")
        } catch UpdateCheckError.network {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testService_scenarioH_rateLimitHeader_surfacesRateLimited() async {
        let service = makeNetworkService { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["x-ratelimit-remaining": "0"]
            )!
            return (Data(), response)
        }
        do {
            _ = try await service.fetchLatestRelease(forceRefresh: true)
            XCTFail("Expected rateLimited error")
        } catch UpdateCheckError.rateLimited {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testService_missingRelease_surfacesInvalidRelease() async {
        let service = makeNetworkService { _ in
            (Data("{\"message\":\"Not Found\"}".utf8), 404)
        }
        do {
            _ = try await service.fetchLatestRelease(forceRefresh: true)
            XCTFail("Expected invalidRelease error")
        } catch UpdateCheckError.invalidRelease {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testService_cachesSuccessfulResultUntilTTL() async throws {
        let counter = RequestCounter()
        let service = makeNetworkService { _ in
            counter.count += 1
            return (ReleaseFixture.json(tag: "v2.0.2"), 200)
        }

        _ = try await service.fetchLatestRelease(forceRefresh: false)
        _ = try await service.fetchLatestRelease(forceRefresh: false)
        XCTAssertEqual(counter.count, 1, "Cached result must not hit the network again")

        _ = try await service.fetchLatestRelease(forceRefresh: true)
        XCTAssertEqual(counter.count, 2, "Manual check must force a refresh")
    }

    func testService_doesNotCacheErrors() async {
        var shouldFail = true
        let service = makeNetworkService { _ in
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return (ReleaseFixture.json(tag: "v2.0.2"), 200)
        }

        do {
            _ = try await service.fetchLatestRelease(forceRefresh: true)
            XCTFail("Expected network error")
        } catch UpdateCheckError.network {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        shouldFail = false
        do {
            _ = try await service.fetchLatestRelease(forceRefresh: true)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Helpers

    private final class RequestCounter {
        var count = 0
    }

    private func makeNetworkService(
        handler: @escaping (URLRequest) throws -> (Data, Int)
    ) -> GitHubReleaseService {
        makeNetworkService { request in
            let (data, statusCode) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
    }

    private func makeNetworkService(
        handler: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)
    ) -> GitHubReleaseService {
        URLProtocolStub.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return GitHubReleaseService(session: session)
    }
}

// MARK: - URLProtocol stub

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolStub.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
