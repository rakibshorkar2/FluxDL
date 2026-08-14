import XCTest
@testable import FluxDL

/// Tests for the global AI search subsystem in Directory Mode:
/// normalization, ranking, query parsing, root isolation, index lifecycle,
/// and Gemini fallback behavior. Pure unit tests â€” no networking, no UI.
final class DirectorySearchTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(
        _ name: String,
        path: String = "",
        size: Int64? = 1_000_000,
        type: DirectoryItemType = .file
    ) -> CrawledFile {
        let joined = path.isEmpty ? "\(name)" : "\(path)/\(name)"
        return CrawledFile(
            name: name,
            url: URL(string: "https://example.com/\(joined)")!,
            sizeBytes: size,
            type: type,
            relativePath: joined
        )
    }

    private func makeIndex(_ files: [CrawledFile], isPartial: Bool = false) -> DirectorySearchIndex {
        DirectorySearchIndexBuilder.build(
            files: files,
            root: URL(string: "https://example.com/")!,
            isPartial: isPartial
        )
    }

    // MARK: - Normalization

    func testNormalizerTokenizesAndDecodes() {
        let tokens = DirectoryFilenameNormalizer.tokens(from: "A Bug's Life (1998) 1080p BluRay.mkv")
        XCTAssertTrue(tokens.contains("bugs"))
        XCTAssertTrue(tokens.contains("life"))
        XCTAssertTrue(tokens.contains("1998"))
        XCTAssertTrue(tokens.contains("1080p"))
        XCTAssertTrue(tokens.contains("bluray"))
        XCTAssertEqual(
            DirectoryFilenameNormalizer.normalized(from: "A.Bugs.Life.1998.mkv"),
            "a bugs life 1998 mkv"
        )
    }

    func testNormalizerFindsSeasonEpisodeTokens() {
        let tokens = DirectoryFilenameNormalizer.tokens(from: "Show S02E05.mkv")
        XCTAssertTrue(tokens.contains("s02"))
        XCTAssertTrue(tokens.contains("e05"))
        XCTAssertTrue(DirectoryFilenameNormalizer.isSeasonEpisodeToken("s02"))
        XCTAssertTrue(DirectoryFilenameNormalizer.isSeasonEpisodeToken("e05"))
        XCTAssertFalse(DirectoryFilenameNormalizer.isSeasonEpisodeToken("2002"))
    }

    func testNormalizerExtractsResolution() {
        XCTAssertEqual(DirectoryFilenameNormalizer.canonicalResolution(for: "1080p"), "1080p")
        XCTAssertEqual(DirectoryFilenameNormalizer.canonicalResolution(for: "720p"), "720p")
        XCTAssertEqual(DirectoryFilenameNormalizer.canonicalResolution(for: "4k"), "2160p")
        XCTAssertEqual(DirectoryFilenameNormalizer.canonicalResolution(for: "UHD"), "2160p")
        XCTAssertEqual(DirectoryFilenameNormalizer.resolution(in: "Movie.4K.mkv"), "2160p")
        XCTAssertNil(DirectoryFilenameNormalizer.canonicalResolution(for: "fhd"))
    }

    func testNormalizerExtractsYear() {
        XCTAssertEqual(DirectoryFilenameNormalizer.year(in: "A Bugs Life (1998) 1080p.mkv"), 1998)
        XCTAssertNil(DirectoryFilenameNormalizer.year(in: "NoYearHere.mkv"))
    }

    // MARK: - Ranking

    func testExactNameRanksFirst() {
        let index = makeIndex([
            makeFile("a-bugs-life.1998.1080p.mkv"),
            makeFile("bugs-life-remaster.1998.1080p.mkv"),
            makeFile("bugs.1998.1080p.mkv"),
        ])
        let results = DirectorySearchEngine.search(index: index, query: DirectoryQueryParser.parse("a bugs life 1998 1080p"))
        XCTAssertEqual(results.first?.entry.filename, "a-bugs-life.1998.1080p.mkv")
    }

    func testFolderMatchRanksAboveFileInIt() {
        let index = makeIndex([
            makeFile("Shrek", path: "Movies", type: .directory),
            makeFile("Shrek.Trailer.mp4", path: "Movies/Shrek"),
        ])
        let results = DirectorySearchEngine.search(index: index, query: DirectoryQueryParser.parse("shrek"))
        XCTAssertEqual(results.first?.entry.filename, "Shrek")
    }

    func testRelativePathContribution() {
        let index = makeIndex([
            makeFile("the-file.mkv", path: "Superhero Franchise (2026)"),
            makeFile("the-file.mkv", path: "Other"),
        ])
        let results = DirectorySearchEngine.search(index: index, query: DirectoryQueryParser.parse("superhero franchise"))
        XCTAssertEqual(results.first?.entry.relativePath, "Superhero Franchise (2026)/the-file.mkv")
    }

    func testFuzzyPrefixMatch() {
        let index = makeIndex([
            makeFile("interstellar.2014.1080p.mkv"),
            makeFile("introduction-to-math.mp4"),
        ])
        let results = DirectorySearchEngine.search(index: index, query: DirectoryQueryParser.parse("interstella"))
        XCTAssertEqual(results.first?.entry.filename, "interstellar.2014.1080p.mkv")
    }

    func testGluedTokenMatch() {
        let index = makeIndex([
            makeFile("spiderman.2012.1080p.mkv"),
            makeFile("spider-plant-guide.mp4"),
        ])
        let results = DirectorySearchEngine.search(index: index, query: DirectoryQueryParser.parse("spiderman"))
        XCTAssertEqual(results.first?.entry.filename, "spiderman.2012.1080p.mkv")
    }

    // MARK: - Query parsing

    func testQueryParserExtractsYear() {
        let query = DirectoryQueryParser.parse("bugs life 1998")
        XCTAssertEqual(query.year, 1998)
        XCTAssertTrue(query.textTerms.contains("bugs"))
        XCTAssertFalse(query.textTerms.contains("1998"))
    }

    func testQueryParserExtractsResolutionAndType() {
        let query = DirectoryQueryParser.parse("movie 1080p")
        XCTAssertEqual(query.resolution, "1080p")
        XCTAssertEqual(query.mediaType, .video)
    }

    func testQueryParserExtractsSizeFilter() {
        let larger = DirectoryQueryParser.parse("larger than 2 GB")
        XCTAssertEqual(larger.minSizeBytes, 2 * 1024 * 1024 * 1024)

        let smaller = DirectoryQueryParser.parse("smaller than 500 MB")
        XCTAssertEqual(smaller.maxSizeBytes, 500 * 1024 * 1024)
    }

    func testQueryParserExtractsExtension() {
        let query = DirectoryQueryParser.parse("final cut .mp4")
        XCTAssertEqual(query.fileExtension, "mp4")
        XCTAssertTrue(query.textTerms.contains("final"))
        XCTAssertTrue(query.textTerms.contains("cut"))
    }

    func testQueryParserExpandsSeasonEpisode() {
        let query = DirectoryQueryParser.parse("season 2 episode 5")
        XCTAssertTrue(query.textTerms.contains("s02"))
        XCTAssertTrue(query.textTerms.contains("e05"))
    }

    func testSizeFilterIsMandatory() {
        let index = makeIndex([
            makeFile("big-movie.mkv", size: 1_000_000, type: .video),
        ])
        let filtered = DirectorySearchEngine.search(
            index: index,
            query: DirectoryQueryParser.parse("movie larger than 10 GB")
        )
        XCTAssertTrue(filtered.isEmpty)
        let matching = DirectorySearchEngine.search(
            index: index,
            query: DirectoryQueryParser.parse("movie smaller than 10 GB")
        )
        XCTAssertEqual(matching.first?.entry.filename, "big-movie.mkv")
    }

    func testTypeFilterIsMandatory() {
        let index = makeIndex([
            makeFile("photo.jpg", type: .image),
            makeFile("movie.mkv", type: .video),
        ])
        let videos = DirectorySearchEngine.search(index: index, query: DirectoryQueryParser.parse("videos"))
        XCTAssertEqual(videos.map(\.entry.filename), ["movie.mkv"])
    }

    func testResolutionFilterIsMandatory() {
        let index = makeIndex([
            makeFile("movie.720p.mkv", type: .video),
            makeFile("movie.1080p.mkv", type: .video),
        ])
        let results = DirectorySearchEngine.search(index: index, query: DirectoryQueryParser.parse("movie 4k"))
        XCTAssertTrue(results.isEmpty, "no entry is 2160p, so the mandatory filter excludes both")
    }

    func testResultLimit() {
        let files = (0..<120).map { makeFile("common-name-\($0).mkv") }
        let results = DirectorySearchEngine.search(index: makeIndex(files), query: DirectoryQueryParser.parse("common name"))
        XCTAssertLessThanOrEqual(results.count, 50)
    }

    func testStopwordsIgnored() {
        let query = DirectoryQueryParser.parse("find the bugs movie please")
        XCTAssertFalse(query.textTerms.contains("find"))
        XCTAssertFalse(query.textTerms.contains("the"))
        XCTAssertFalse(query.textTerms.contains("please"))
        XCTAssertTrue(query.textTerms.contains("bugs"))
    }

    // MARK: - Root key isolation

    func testRootKeyNormalizesPath() {
        let a = DirectorySearchRootKey.key(for: URL(string: "https://example.com/Movies/../Docs/./movie.mkv")!)
        let b = DirectorySearchRootKey.key(for: URL(string: "https://example.com/Docs/movie.mkv")!)
        XCTAssertEqual(a, b)
        XCTAssertEqual(DirectorySearchRootKey.cacheFileName(for: a), DirectorySearchRootKey.cacheFileName(for: b))
    }

    func testRootKeySeparatesHosts() {
        let a = DirectorySearchRootKey.key(for: URL(string: "https://example.com/")!)
        let b = DirectorySearchRootKey.key(for: URL(string: "https://other.org/")!)
        XCTAssertNotEqual(a, b)
    }

    func testRootKeySeparatesPortsAndSchemes() {
        let http = DirectorySearchRootKey.key(for: URL(string: "http://example.com/")!)
        let https = DirectorySearchRootKey.key(for: URL(string: "https://example.com/")!)
        let ported = DirectorySearchRootKey.key(for: URL(string: "https://example.com:8080/")!)
        XCTAssertNotEqual(http, https)
        XCTAssertNotEqual(http, ported)
    }

    func testRootKeyRejectsEscapes() {
        let a = DirectorySearchRootKey.key(for: URL(string: "https://example.com/%2e%2e/etc")!)
        let b = DirectorySearchRootKey.key(for: URL(string: "https://example.com/etc")!)
        XCTAssertEqual(a, b, "percent-encoded dot segments resolve identically")
    }

    // MARK: - Index lifecycle

    func testIndexCacheRoundTrip() throws {
        let index = makeIndex([
            makeFile("movie.mkv"),
        ])
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(DirectorySearchIndex.self, from: data)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries.first?.filename, "movie.mkv")
        XCTAssertEqual(decoded.rootKey, DirectorySearchRootKey.key(for: URL(string: "https://example.com/")!))
        XCTAssertFalse(decoded.isPartial)
    }

    func testPartialIndexRoundTrip() throws {
        let partial = makeIndex([makeFile("x.mkv")], isPartial: true)
        let data = try JSONEncoder().encode(partial)
        let decoded = try JSONDecoder().decode(DirectorySearchIndex.self, from: data)
        XCTAssertTrue(decoded.isPartial)
    }

    func testEmptyIndexReturnsNoResults() {
        let results = DirectorySearchEngine.search(index: makeIndex([]), query: DirectoryQueryParser.parse("anything"))
        XCTAssertTrue(results.isEmpty)
    }

    func testIndexBuilderCapturesMetadata() {
        let index = makeIndex([makeFile("Movie.1998.1080p.BluRay.mkv", path: "Cartoons")])
        let entry = try! XCTUnwrap(index.entries.first)
        XCTAssertEqual(entry.year, 1998)
        XCTAssertEqual(entry.resolution, "1080p")
        XCTAssertEqual(entry.fileExtension, "mkv")
        XCTAssertEqual(entry.relativePath, "Cartoons/Movie.1998.1080p.BluRay.mkv")
        XCTAssertTrue(entry.tokens.contains("cartoons"))
        XCTAssertTrue(entry.metadataTokens.contains("bluray"))
    }

    // MARK: - Gemini behavior (mocked HTTP + mock keychain)

    private final class MockAIKeychain: DirectoryAIKeychainStoring {
        var stored: String?
        func apiKey() -> String? { stored }
        func saveAPIKey(_ key: String) { stored = key }
        func deleteAPIKey() { stored = nil }
    }

    private func geminiEnvelope(_ inner: [String: Any]) -> Data {
        let innerData = try! JSONSerialization.data(withJSONObject: inner)
        let envelope: [String: Any] = [
            "candidates": [
                ["content": ["parts": [["text": String(data: innerData, encoding: .utf8)!]]]]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    func testGeminiServiceSendsHeaderAndStrictDecodes() async throws {
        let session = URLSession.mock(handler: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret-test-key")
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        }, bodyData: { _ in
            self.geminiEnvelope(["textTerms": ["bugs", "life"], "year": 1998, "mediaType": "video"])
        })

        let keychain = MockAIKeychain()
        keychain.saveAPIKey("secret-test-key")
        let service = GeminiDirectorySearchService(
            session: session,
            keychain: keychain,
            timeout: 5
        )
        let query = try await service.interpret(query: "find the bugs movie from 1998")
        XCTAssertEqual(query.textTerms, ["bugs", "life"])
        XCTAssertEqual(query.year, 1998)
        XCTAssertEqual(query.mediaType, .video)
    }

    func testGeminiServiceUnconfiguredWhenNoKey() {
        let service = GeminiDirectorySearchService(keychain: MockAIKeychain())
        XCTAssertFalse(service.isConfigured)
        let keyed = MockAIKeychain()
        keyed.saveAPIKey("k")
        XCTAssertTrue(GeminiDirectorySearchService(keychain: keyed).isConfigured)
    }

    func testGeminiMissingKeyFallsBack() async {
        let session = URLSession.mock(handler: { _ in
            HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }, bodyData: { _ in Data() })

        let service = GeminiDirectorySearchService(keychain: MockAIKeychain(), session: session, timeout: 5)
        do {
            _ = try await service.interpret(query: "anything")
            XCTFail("Expected missing-key to throw")
        } catch {
            // Caller falls back to local search.
        }
    }

    func testGeminiInvalidJSONFallsBack() async {
        let session = URLSession.mock(handler: { _ in
            HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }, bodyData: { _ in Data("not json at all".utf8) })

        let keychain = MockAIKeychain()
        keychain.saveAPIKey("k")
        let service = GeminiDirectorySearchService(session: session, keychain: keychain, timeout: 5)
        do {
            _ = try await service.interpret(query: "anything")
            XCTFail("Expected invalid response to throw")
        } catch {
            // Caller falls back to local search.
        }
    }

    func testGeminiUnexpectedShapeFallsBack() async {
        let session = URLSession.mock(handler: { _ in
            HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }, bodyData: { _ in
            self.geminiEnvelope(["notTheExpectedSchema": true])
        })

        let keychain = MockAIKeychain()
        keychain.saveAPIKey("k")
        let service = GeminiDirectorySearchService(session: session, keychain: keychain, timeout: 5)
        do {
            _ = try await service.interpret(query: "anything")
            XCTFail("Expected unexpected-shape to throw")
        } catch {
            // Caller falls back to local search.
        }
    }

    func testGeminiTimeoutFallsBack() async {
        let session = URLSession.mock(handler: { _ in
            HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }, bodyData: { _ in
            Thread.sleep(forTimeInterval: 3)
            return Data()
        })

        let keychain = MockAIKeychain()
        keychain.saveAPIKey("k")
        let service = GeminiDirectorySearchService(session: session, keychain: keychain, timeout: 1)
        do {
            _ = try await service.interpret(query: "anything")
            XCTFail("Expected timeout to throw")
        } catch GeminiDirectorySearchError.timeout {
            // Caller falls back to local search.
        }
    }
}

// MARK: - URLProtocol-based mock session

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> HTTPURLResponse)?
    nonisolated(unsafe) static var bodyData: ((URLRequest) -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data = Self.bodyData?(request) ?? Data()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSession {
    static func mock(
        handler: @escaping (URLRequest) -> HTTPURLResponse,
        bodyData: @escaping (URLRequest) -> Data
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = handler
        MockURLProtocol.bodyData = bodyData
        return URLSession(configuration: config)
    }
}