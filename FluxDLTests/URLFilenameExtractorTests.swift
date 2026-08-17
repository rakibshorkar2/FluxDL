import XCTest
@testable import FluxDL

final class URLFilenameExtractorTests: XCTestCase {
    
    func testGoogleDriveURLParsing() {
        let urlString = "https://drive.usercontent.google.com/download?id=1W2GDkR2fShdiU8Ld79ECIyJ61F9P4zWO&export=download&authuser=7&confirm=t&uuid=8be52d41-e310-4d41-9d4d-cbb59f6773f7&at=AFYLz4O7mRcHNxvgJmIKjA0Q2eAT%3A1785912151035"
        let url = URL(string: urlString)!
        let filename = URLFilenameExtractor.extractFilename(from: url)
        
        XCTAssertEqual(filename, "gdrive_1W2GDkR2")
    }
    
    func testSeedrURLParsing() {
        let urlString = "https://www.seedr.cc/download/archive/c01d9c34243bc62f5263d1cd726b09165cad4c237eca7378f5aa1e37d91efd9a?token=637d1ce18e71d9b0b727b8e15443d9a9df40c8e86ce8a280b7693a92362b4c29&exp=1785998581"
        let url = URL(string: urlString)!
        let filename = URLFilenameExtractor.extractFilename(from: url)
        
        XCTAssertEqual(filename, "seedr_d91efd9a")
    }
    
    func testCloudflareR2URLParsingWithQueryParam() {
        let urlString = "https://bbbb.bf3cbb52f6d8359ccc60ce1f0be2ff5d.r2.cloudflarestorage.com/e9512207ccecb3ea98e91ad8cf1c6244/SpiderMan-Brand.New.Day.2026.V3.HDTC.Dual.480p.mkv?response-content-disposition=attachment%3B%20filename%3D%22SpiderMan-Brand.New.Day.2026.V3.HDTC.Dual.480p.mkv%22&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=4f5df99d89732833b1ae4696a9f77bb7%2F20260805%2Fauto%2Fs3%2Faws4_request&X-Amz-Date=20260805T062128Z&X-Amz-SignedHeaders=host&X-Amz-Expires=14400&X-Amz-Signature=f2bd6ad85e6dc809e028383d440fe1c6d5087731c0dbf34b29d30c847bcbd919"
        let url = URL(string: urlString)!
        let filename = URLFilenameExtractor.extractFilename(from: url)
        
        XCTAssertEqual(filename, "SpiderMan-Brand.New.Day.2026.V3.HDTC.Dual.480p.mkv")
    }
    
    func testContentDispositionHeaderExtraction() {
        let header = "attachment; filename=\"MyDocument.pdf\""
        let filename = URLFilenameExtractor.extractFilename(fromContentDisposition: header)
        
        XCTAssertEqual(filename, "MyDocument.pdf")
    }
}
