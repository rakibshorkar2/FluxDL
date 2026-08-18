import XCTest
import LibTorrent
@testable import FluxDL

/// Tests for the document-import compatibility helper. These never require a
/// device or LiveContainer — they verify the local-copy, validation and
/// cleanup contract that the YAML and `.torrent` import flows rely on.
final class ImportedDocumentReaderTests: XCTestCase {

    private var sourceDirectory: URL!

    override func setUp() {
        super.setUp()
        sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedDocumentReaderTests.\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sourceDirectory)
        ImportedDocumentReader.cleanupStaleTemporaryCopies()
        super.tearDown()
    }

    private func makeFile(_ name: String, contents: String) -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        try! Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Readability

    func testAppLocalFileIsReturnedAsIs() {
        let url = makeFile("config.yaml", contents: "proxies: []\n")

        let result = ImportedDocumentReader.readableCopy(of: url, preferredExtension: "yaml")

        guard case .success(let localURL) = result else {
            return XCTFail("app-local file must be readable without a copy")
        }
        XCTAssertEqual(localURL, url, "app-local files must be used directly")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: localURL.path))
    }

    func testCopiedFileIsReadable() {
        let url = makeFile("sample.torrent", contents: "d4:info4:teste")
        guard case .success(let copied) = ImportedDocumentReader.copyToTemporaryDirectory(from: url, preferredExtension: "torrent") else {
            return XCTFail("copy must succeed")
        }
        defer { ImportedDocumentReader.removeTemporaryCopy(at: copied) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: copied.path))
        XCTAssertEqual(copied.pathExtension, "torrent", "the preferred extension must be preserved")

        // The copied file is app-local, so readableCopy uses it as-is.
        guard case .success(let localURL) = ImportedDocumentReader.readableCopy(of: copied, preferredExtension: "torrent") else {
            return XCTFail("the copy must be readable")
        }
        XCTAssertEqual(localURL, copied)
    }

    func testMissingFileFailsWithCleanError() {
        let url = sourceDirectory.appendingPathComponent("does-not-exist.yaml")

        let result = ImportedDocumentReader.readableCopy(of: url, preferredExtension: "yaml")

        guard case .failure(let error) = result else {
            return XCTFail("a missing file must fail")
        }
        XCTAssertEqual(error, .fileUnavailable)
        XCTAssertEqual(error.userMessage, "Could not open the selected file.",
                       "errors must be user-facing and never expose paths")
    }

    func testUnreadableFileFailsWithCleanError() {
        let url = makeFile("locked.yaml", contents: "proxies: []\n")
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let result = ImportedDocumentReader.readableCopy(of: url, preferredExtension: "yaml")

        guard case .failure = result else {
            return XCTFail("an unreadable file must fail")
        }
        XCTAssertEqual(result.failureMessage(), "Could not open the selected file.")
    }

    // MARK: - Reading

    func testReadTextDecodesUTF8() {
        let url = makeFile("config.yaml", contents: "proxies:\n  - name: 日本語\n")

        let result = ImportedDocumentReader.readText(from: url)

        XCTAssertEqual(try? result.get(), "proxies:\n  - name: 日本語\n")
    }

    func testReadTextStripsUTF8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("proxies: []\n".utf8))
        let url = sourceDirectory.appendingPathComponent("bom.yaml")
        try! data.write(to: url)

        let result = ImportedDocumentReader.readText(from: url)

        XCTAssertEqual(try? result.get(), "proxies: []\n", "a leading BOM must be stripped")
    }

    func testReadTextRejectsInvalidEncoding() {
        let url = sourceDirectory.appendingPathComponent("binary.yaml")
        try! Data([0xE9, 0xE9, 0xFF, 0xFE]).write(to: url)

        let result = ImportedDocumentReader.readText(from: url)

        guard case .failure(let error) = result else {
            return XCTFail("invalid UTF-8 must fail")
        }
        XCTAssertEqual(error, .invalidEncoding)
        XCTAssertEqual(error.userMessage, "The selected file could not be read as UTF-8 text.")
    }

    // MARK: - Document classification

    func testYAMLDocumentExtensionsAccepted() {
        XCTAssertTrue(ImportedDocumentReader.isYAMLDocument(URL(fileURLWithPath: "/tmp/config.yaml")))
        XCTAssertTrue(ImportedDocumentReader.isYAMLDocument(URL(fileURLWithPath: "/tmp/config.yml")))
        XCTAssertTrue(ImportedDocumentReader.isYAMLDocument(URL(fileURLWithPath: "/tmp/config.YAML")),
                      "extensions must be case-insensitive")
        XCTAssertFalse(ImportedDocumentReader.isYAMLDocument(URL(fileURLWithPath: "/tmp/config.txt")))
        XCTAssertFalse(ImportedDocumentReader.isYAMLDocument(URL(fileURLWithPath: "/tmp/movie.mp4")))
    }

    func testTorrentDocumentExtensionAccepted() {
        XCTAssertTrue(ImportedDocumentReader.isTorrentDocument(URL(fileURLWithPath: "/tmp/sample.torrent")))
        XCTAssertTrue(ImportedDocumentReader.isTorrentDocument(URL(fileURLWithPath: "/tmp/sample.TORRENT")))
        XCTAssertFalse(ImportedDocumentReader.isTorrentDocument(URL(fileURLWithPath: "/tmp/sample.txt")))
    }

    func testMp4IsRejectedByTorrentValidation() {
        let url = makeFile("movie.mp4", contents: "not a torrent at all")

        XCTAssertFalse(ImportedDocumentReader.isTorrentDocument(url))
        XCTAssertNil(TorrentFile(with: url), "arbitrary files must never be treated as torrents")
    }

    func testInvalidTorrentBytesAreRejected() {
        let url = makeFile("broken.torrent", contents: "this is not bencoded")

        XCTAssertTrue(ImportedDocumentReader.isTorrentDocument(url))
        XCTAssertNil(TorrentFile(with: url), "bogus .torrent content must be rejected by the authoritative parser")
    }

    // MARK: - Cleanup

    func testRemoveTemporaryCopyOnlyDeletesOwnCopies() {
        let url = makeFile("config.yaml", contents: "proxies: []\n")
        guard case .success(let copied) = ImportedDocumentReader.copyToTemporaryDirectory(from: url, preferredExtension: "yaml") else {
            return XCTFail("copy must succeed")
        }

        ImportedDocumentReader.removeTemporaryCopy(at: copied)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path), "the temporary copy must be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the user's original file must never be deleted")
    }

    func testCleanupStaleTemporaryCopiesEmptiesImportDirectory() {
        let url = makeFile("config.yaml", contents: "proxies: []\n")
        guard case .success(let copied) = ImportedDocumentReader.copyToTemporaryDirectory(from: url, preferredExtension: "yaml") else {
            return XCTFail("copy must succeed")
        }

        ImportedDocumentReader.cleanupStaleTemporaryCopies()

        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

private extension Result where Failure == ImportedDocumentError {
    func failureMessage() -> String? {
        guard case .failure(let error) = self else { return nil }
        return error.userMessage
    }
}