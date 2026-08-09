import XCTest
@testable import FluxDL

@MainActor
final class QueueManagerTests: XCTestCase {
    var queueManager: QueueManager!
    var storageManager: StorageManager!
    
    override func setUp() {
        super.setUp()
        queueManager = QueueManager()
        storageManager = StorageManager()
    }
    
    override func tearDown() {
        queueManager = nil
        storageManager = nil
        super.tearDown()
    }
    
    func testQueueManagerDefaults() {
        XCTAssertGreaterThan(queueManager.maxConcurrentDownloads, 0)
        XCTAssertEqual(queueManager.queueMode, .parallel)
        XCTAssertTrue(queueManager.autoRetryEnabled)
        XCTAssertTrue(queueManager.duplicateDetectionEnabled)
    }
    
    func testPriorityOrdering() {
        let lowTask = DownloadTaskModel(url: URL(string: "https://example.com/low.zip")!, priority: .low)
        let highTask = DownloadTaskModel(url: URL(string: "https://example.com/high.zip")!, priority: .high)
        let normalTask = DownloadTaskModel(url: URL(string: "https://example.com/normal.zip")!, priority: .normal)
        
        let sorted = [lowTask, highTask, normalTask].sorted { $0.priority > $1.priority }
        XCTAssertEqual(sorted.first?.id, highTask.id)
        XCTAssertEqual(sorted.last?.id, lowTask.id)
    }
    
    func testStorageManagerDiskCalculations() {
        XCTAssertGreaterThan(storageManager.totalDiskSpaceBytes, 0)
        XCTAssertGreaterThan(storageManager.freeDiskSpaceBytes, 0)
        XCTAssertFalse(storageManager.formattedFreeDiskSpace.isEmpty)
        XCTAssertTrue(storageManager.isDiskSpaceSufficient(for: 1_000_000))
    }
}
