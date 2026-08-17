import XCTest
@testable import FluxDL

final class ChecksumTests: XCTestCase {
    
    func testHashComputation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("checksum_test_\(UUID().uuidString).txt")
        let testString = "FluxDL Fast Download Manager 2026"
        try testString.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        
        let sha256 = try ChecksumVerifier.computeHash(for: fileURL, algorithm: .sha256)
        let md5 = try ChecksumVerifier.computeHash(for: fileURL, algorithm: .md5)
        
        XCTAssertFalse(sha256.isEmpty)
        XCTAssertEqual(sha256.count, 64, "SHA-256 string must be 64 hex characters")
        XCTAssertFalse(md5.isEmpty)
        XCTAssertEqual(md5.count, 32, "MD5 string must be 32 hex characters")
        
        let isValid = try ChecksumVerifier.verify(fileURL: fileURL, expectedHash: sha256, algorithm: .sha256)
        XCTAssertTrue(isValid, "Checksum verification must return true for matching hash")
    }
}
