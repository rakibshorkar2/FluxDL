import XCTest
@testable import FluxDL

final class DownloadEngineTests: XCTestCase {
    func testDownloadTaskModelProgressAndFormatting() {
        let url = URL(string: "https://example.com/test.zip")!
        let task = DownloadTaskModel(
            url: url,
            filename: "test.zip",
            status: .downloading,
            totalBytes: 100_000_000,
            downloadedBytes: 50_000_000,
            speedBytesPerSec: 5_000_000,
            remainingTimeSeconds: 10
        )
        
        XCTAssertEqual(task.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(task.formattedETA, "00:10")
        XCTAssertFalse(task.formattedSpeed.isEmpty)
        XCTAssertEqual(task.filename, "test.zip")
    }
    
    func testDownloadRepositorySaveAndLoad() {
        let repo = DownloadRepository()
        let url = URL(string: "https://example.com/sample.pdf")!
        let task = DownloadTaskModel(url: url, filename: "sample.pdf", status: .paused)
        
        repo.saveTasks([task])
        let loadedTasks = repo.loadTasks()
        
        XCTAssertTrue(loadedTasks.contains(where: { $0.id == task.id }))
    }
    
    func testFileManagementServiceDestinationURL() {
        let service = FileManagementService()
        let dest = service.destinationURL(for: "archive.zip")
        XCTAssertEqual(dest.lastPathComponent, "archive.zip")
        XCTAssertTrue(dest.path.contains("Downloads"))
    }
}
