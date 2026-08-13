import XCTest
@testable import FluxDL

final class DirectoryParserTests: XCTestCase {

    private let base = URL(string: "http://example.com/files/")!

    // MARK: - Apache listings

    func testApacheListingParsesSizesAndDates() {
        let html = """
        <html><head><title>Index of /files</title></head>
        <body><table>
        <tr><th>Name</th><th>Last modified</th><th>Size</th><th>Description</th></tr>
        <tr><td><a href="../">Parent Directory</a></td><td>&nbsp;</td><td>-</td><td>&nbsp;</td></tr>
        <tr><td><a href="movies/">movies/</a></td><td>2026-01-02 03:04</td><td>-</td><td>&nbsp;</td></tr>
        <tr><td><a href="movie.mp4">movie.mp4</a></td><td>2026-01-02 03:04</td><td>1.2G</td><td>&nbsp;</td></tr>
        <tr><td><a href="small.zip">small.zip</a></td><td>2025-12-31 23:59</td><td>512K</td><td>&nbsp;</td></tr>
        <tr><td><a href="tiny.txt">tiny.txt</a></td><td>2025-01-01 00:00</td><td>5</td><td>&nbsp;</td></tr>
        </table></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)

        XCTAssertEqual(result.listingStyle, .apache)
        XCTAssertEqual(result.items.count, 4)
        XCTAssertTrue(result.hasParentLink)

        let folder = result.items[0]
        XCTAssertEqual(folder.name, "movies")
        XCTAssertEqual(folder.type, .directory)
        XCTAssertEqual(folder.url.absoluteString, "http://example.com/files/movies/")

        let video = result.items[1]
        XCTAssertEqual(video.type, .video)
        XCTAssertEqual(video.sizeBytes, 1_288_490_188)

        let zip = result.items[2]
        XCTAssertEqual(zip.type, .archive)
        XCTAssertEqual(zip.sizeBytes, 524_288)

        let text = result.items[3]
        XCTAssertEqual(text.type, .other)
        XCTAssertEqual(text.sizeBytes, 5)
    }

    func testApacheDateParsing() {
        XCTAssertNotNil(DirectoryHTMLParser.parseDate("2026-01-02 03:04"))
        XCTAssertNotNil(DirectoryHTMLParser.parseDate("2026-01-02 03:04:05"))
        XCTAssertNotNil(DirectoryHTMLParser.parseDate("2026-01-02"))
        XCTAssertNil(DirectoryHTMLParser.parseDate("02-Jan-2026 03:04"))
        XCTAssertNil(DirectoryHTMLParser.parseDate("not a date"))
    }

    func testNGINXStyleTrailingSizeAndDate() {
        let html = """
        <html><head><title>Index of /pub</title></head><body>
        <a href="../">../</a>
        <a href="movie.mkv">movie.mkv</a> 1.5G 2026-03-04 05:06
        <a href="notes.txt">notes.txt</a> 2K 2026-03-04 05:06
        <br></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)

        XCTAssertEqual(result.listingStyle, .generic)
        XCTAssertEqual(result.items.count, 2)
        let movie = result.items[0]
        XCTAssertEqual(movie.type, .video)
        XCTAssertEqual(movie.sizeBytes, 1_610_612_736)
        XCTAssertNotNil(movie.modifiedDate)
        let notes = result.items[1]
        XCTAssertEqual(notes.sizeBytes, 2048)
    }

    // MARK: - Link handling

    func testSkipsIrrelevantLinks() {
        let html = """
        <html><body>
        <a href="?C=N;O=D">Name</a>
        <a href="?C=S;O=A">Size</a>
        <a href="#top">Top</a>
        <a href="../">Parent</a>
        <a href="/">Root</a>
        <a href=""></a>
        <a href="mailto:admin@example.com">Mail</a>
        <a href="javascript:void(0)">JS</a>
        <a href="real.txt">real.txt</a>
        </body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].name, "real.txt")
    }

    func testRelativeResolutionAndPercentEncoding() {
        let html = """
        <html><body>
        <a href="sub%20folder/">sub folder/</a>
        <a href="../sibling.txt">sibling.txt</a>
        <a href="http://other.example.org/x.mp3">x.mp3</a>
        </body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)

        let folder = result.items.first { $0.type == .directory }
        XCTAssertEqual(folder?.url.absoluteString, "http://example.com/files/sub%20folder/")
        XCTAssertEqual(folder?.name, "sub folder")

        let sibling = result.items.first { $0.name == "sibling.txt" }
        XCTAssertEqual(sibling?.url.absoluteString, "http://example.com/sibling.txt")

        let external = result.items.first { $0.name == "x.mp3" }
        XCTAssertEqual(external?.type, .audio)
        XCTAssertEqual(external?.url.absoluteString, "http://other.example.org/x.mp3")
    }

    func testUnicodeNames() {
        let html = """
        <html><body><a href="%E0%A6%AC%E0%A6%99%E0%A7%8D%E0%A6%97%E0%A6%B2%E0%A6%BE.mp3">বাংলা.mp3</a></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].name, "বাংলা.mp3")
        XCTAssertEqual(result.items[0].type, .audio)
    }

    // MARK: - Detection

    func testEmptyDirectoryIsStillADirectory() {
        let html = """
        <html><head><title>Index of /empty</title></head>
        <body><table><tr><th>Name</th><th>Last modified</th><th>Size</th></tr>
        <tr><td><a href="../">Parent Directory</a></td><td>&nbsp;</td><td>-</td></tr>
        </table></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        XCTAssertTrue(result.hasParentLink)
        XCTAssertEqual(result.items.count, 0)
        XCTAssertTrue(DirectoryDetector.isOpenDirectory(result, contentType: "text/html"))
    }

    func testGenericHTMLIsNotADirectory() {
        let html = """
        <html><head><title>My Homepage</title></head>
        <body><h1>Welcome</h1><p>This is a normal website.</p>
        <a href="/about">About</a><a href="/contact">Contact</a>
        </body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        XCTAssertFalse(result.hasParentLink)
        XCTAssertFalse(result.hasListingMarker)
        XCTAssertFalse(DirectoryDetector.isOpenDirectory(result, contentType: "text/html"))
    }

    func testGenericHTMLWithDirectoryAnchorsIsADirectory() {
        let html = """
        <html><body>
        <a href="file1.zip">file1.zip</a> 1.2M
        <a href="file2.zip">file2.zip</a> 3.4M
        </body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        XCTAssertEqual(result.directoryAnchorCount, 0)
        XCTAssertEqual(result.anchorCount, 2)
        XCTAssertTrue(DirectoryDetector.isOpenDirectory(result, contentType: "text/html"))
    }

    func testNonHTMLContentTypeIsNotADirectory() {
        let result = DirectoryParseResult(
            items: [],
            isHTML: false,
            hasParentLink: false,
            hasListingMarker: false,
            hasTable: false,
            anchorCount: 0,
            directoryAnchorCount: 0,
            listingStyle: .generic
        )
        XCTAssertFalse(DirectoryDetector.isOpenDirectory(result, contentType: "application/pdf"))
    }

    // MARK: - Sizes

    func testParseSize() {
        XCTAssertEqual(DirectoryHTMLParser.parseSize("5"), 5)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("512K"), 524_288)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1.5M"), 1_572_864)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1.2G"), 1_288_490_188)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1,234"), 1234)
        XCTAssertNil(DirectoryHTMLParser.parseSize("-"))
        XCTAssertNil(DirectoryHTMLParser.parseSize("&nbsp;"))
        XCTAssertNil(DirectoryHTMLParser.parseSize("dir"))
    }

    func testParseSizeVariants() {
        XCTAssertEqual(DirectoryHTMLParser.parseSize("2 KB"), 2048)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("2.0 KB"), 2048)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1.48 GB"), 1_589_137_899)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1.48G"), 1_589_137_899)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1.48 GiB"), 1_589_137_899)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1.48GB"), 1_589_137_899)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1024 MB"), 1_073_741_824)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1,480 MB"), 1_551_892_480)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("1.5 TB"), 1_649_267_441_664)
        XCTAssertEqual(DirectoryHTMLParser.parseSize("500 B"), 500)
        XCTAssertEqual(DirectoryHTMLParser.parseSize(" 1.48G "), 1_589_137_899)
        XCTAssertNil(DirectoryHTMLParser.parseSize(""))
        XCTAssertNil(DirectoryHTMLParser.parseSize("unknown"))
        XCTAssertNil(DirectoryHTMLParser.parseSize("-"))
        XCTAssertNil(DirectoryHTMLParser.parseSize("Last modified"))
        XCTAssertNil(DirectoryHTMLParser.parseSize("A.Bugs.Life.1998.1080p.x264.YIFY.mp4"))
    }

    // MARK: - Regression: filename digits must never be read as a size

    func testLongFilenameWithYearIsNotMisreadAsSize() {
        let html = """
        <html><head><title>Index of /films</title></head><body><table>
        <tr><th>Name</th><th>Last modified</th><th>Size</th><th>Description</th></tr>
        <tr><td><a href="../">Parent Directory</a></td><td>&nbsp;</td><td>-</td><td>&nbsp;</td></tr>
        <tr><td><a href="A.Bugs.Life.1998.1080p.x264.YIFY.mp4">A.Bugs.Life.1998.1080p.x264.YIFY.mp4</a></td><td>2025-04-12 10:14</td><td>1.48G</td><td>&nbsp;</td></tr>
        </table></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        let item = result.items.first
        XCTAssertEqual(item?.name, "A.Bugs.Life.1998.1080p.x264.YIFY.mp4")
        XCTAssertEqual(item?.sizeBytes, 1_589_137_899)
        XCTAssertNotNil(item?.modifiedDate)
    }

    func testNGINXRemainderWithFilenameLikeNumbers() {
        let html = """
        <html><head><title>Index of /pub</title></head><body>
        <a href="../">../</a>
        <a href="A.Bugs.Life.1998.1080p.x264.YIFY.mp4">A.Bugs.Life.1998.1080p.x264.YIFY.mp4</a> 1.48G 2025-04-12 10:14
        <br></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        let item = result.items.first
        XCTAssertEqual(item?.name, "A.Bugs.Life.1998.1080p.x264.YIFY.mp4")
        XCTAssertEqual(item?.sizeBytes, 1_589_137_899)
        XCTAssertNotNil(item?.modifiedDate)
    }

    func testNameContainingSizeLikeTokensIsIgnored() {
        let html = """
        <html><head><title>Index of /x</title></head><body><table>
        <tr><th>Name</th><th>Last modified</th><th>Size</th></tr>
        <tr><td><a href="movie.4K.remux.mkv">movie.4K.remux.mkv</a></td><td>2026-01-01 00:00</td><td>8.9G</td></tr>
        </table></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        let item = result.items.first
        XCTAssertEqual(item?.name, "movie.4K.remux.mkv")
        XCTAssertEqual(item?.sizeBytes, 9_556_302_233)
    }

    // MARK: - Layout variants

    func testThreeColumnNameSizeDateLayout() {
        let html = """
        <html><head><title>Index of /x</title></head><body><table>
        <tr><th>Name</th><th>Size</th><th>Last modified</th></tr>
        <tr><td><a href="big.mkv">big.mkv</a></td><td>4.2G</td><td>2026-02-03 04:05</td></tr>
        </table></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        let item = result.items.first
        XCTAssertEqual(item?.name, "big.mkv")
        XCTAssertEqual(item?.sizeBytes, 4_509_715_660)
        XCTAssertNotNil(item?.modifiedDate)
    }

    func testThreeColumnNameDateSizeLayout() {
        let html = """
        <html><head><title>Index of /x</title></head><body><table>
        <tr><th>Name</th><th>Last modified</th><th>Size</th></tr>
        <tr><td><a href="thing.iso">thing.iso</a></td><td>2026-05-06 07:08</td><td>950 MB</td></tr>
        </table></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        let item = result.items.first
        XCTAssertEqual(item?.name, "thing.iso")
        XCTAssertEqual(item?.sizeBytes, 996_147_200)
        XCTAssertNotNil(item?.modifiedDate)
    }

    func testSizeAndDateInSingleTrailingCell() {
        let html = """
        <html><head><title>Index of /x</title></head><body><table>
        <tr><th>Name</th><th>Details</th></tr>
        <tr><td><a href="pack.tar">pack.tar</a></td><td>2.3G 2026-07-08 09:10</td></tr>
        </table></body></html>
        """
        let result = DirectoryHTMLParser.parse(html: html, baseURL: base)
        let item = result.items.first
        XCTAssertEqual(item?.name, "pack.tar")
        XCTAssertEqual(item?.sizeBytes, 2_469_606_195)
        XCTAssertNotNil(item?.modifiedDate)
    }

    func testFormatter() {
        XCTAssertEqual(DirectoryItemFormatter.string(fromBytes: 5), "5 B")
        XCTAssertEqual(DirectoryItemFormatter.string(fromBytes: 512_000), "500 KB")
        XCTAssertEqual(DirectoryItemFormatter.formattedFileSize(1024), "1 KB")
        XCTAssertEqual(DirectoryItemFormatter.formattedFileSize(1_048_576), "1 MB")
        XCTAssertEqual(DirectoryItemFormatter.formattedFileSize(1_073_741_824), "1 GB")
        XCTAssertEqual(DirectoryItemFormatter.formattedFileSize(0), "0 B")
        XCTAssertEqual(DirectoryItemFormatter.formattedFileSize(1_589_137_899), "1.48 GB")
        XCTAssertEqual(DirectoryItemFormatter.formattedFileSize(nil), "Unknown size")
        XCTAssertNil(DirectoryItemFormatter.string(fromBytes: nil))
    }
}