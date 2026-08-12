import XCTest
import Combine
@testable import FluxDL

final class DownloadHistoryTests: XCTestCase {

    func testHistoryEntryPreservesOriginalURLAfterUpdateLink() {
        let url = URL(string: "https://example.com/file.zip")!
        var task = DownloadTaskModel(url: url, filename: "file.zip", status: .downloading)
        var entry = DownloadHistoryEntry(task: task)

        XCTAssertEqual(entry.originalURL, url)
        XCTAssertEqual(entry.effectiveURL, url)

        // Simulate "Update Link" mutating the task URL
        let newURL = URL(string: "https://cdn.example.com/file.zip")!
        task.url = newURL

        let change = entry.update(from: task)

        XCTAssertEqual(change, .critical)
        XCTAssertEqual(entry.originalURL, url, "Original URL must survive URL updates")
        XCTAssertEqual(entry.effectiveURL, newURL)
        XCTAssertEqual(entry.id, task.id, "History record shares the task's stable UUID")
    }

    func testHistoryEntryTracksCompletion() {
        var task = DownloadTaskModel(url: URL(string: "https://example.com/a.zip")!, filename: "a.zip")
        var entry = DownloadHistoryEntry(task: task)
        XCTAssertNil(entry.completedAt)

        task.status = .completed
        task.completedAt = Date()
        task.totalBytes = 1_000_000
        task.downloadedBytes = 1_000_000

        let change = entry.update(from: task)

        XCTAssertEqual(change, .critical)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertNotNil(entry.completedAt)
        XCTAssertEqual(entry.totalBytes, 1_000_000)
    }

    func testHistoryEntryPreservesFailedRecordAndURL() {
        let url = URL(string: "https://example.com/broken.pdf")!
        var task = DownloadTaskModel(url: url, filename: "broken.pdf", status: .downloading)
        var entry = DownloadHistoryEntry(task: task)

        task.status = .failed
        task.errorMessage = "Connection lost"
        _ = entry.update(from: task)

        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.errorMessage, "Connection lost")
        XCTAssertEqual(entry.originalURL, url)
    }

    func testHistoryMinorProgressChange() {
        let url = URL(string: "https://example.com/big.bin")!
        var task = DownloadTaskModel(url: url, filename: "big.bin", status: .downloading, totalBytes: 10_000, downloadedBytes: 1_000)
        var entry = DownloadHistoryEntry(task: task)

        task.downloadedBytes = 2_000

        XCTAssertEqual(entry.update(from: task), .minor)
        XCTAssertEqual(entry.downloadedBytes, 2_000)
    }

    func testRepositoryHistoryRoundTrip() {
        let repo = DownloadRepository()
        let url = URL(string: "https://example.com/history.zip")!
        let entry = DownloadHistoryEntry(task: DownloadTaskModel(url: url, filename: "history.zip"))

        repo.saveHistory([entry])
        let loaded = repo.loadHistory()

        XCTAssertTrue(loaded.contains(where: { $0.id == entry.id }))
        XCTAssertEqual(loaded.first?.originalURL, url)
    }

    @MainActor
    func testHistoryManagerKeepsRecordWhenTaskRemovedFromEngine() {
        let repo = DownloadRepository()
        let manager = DownloadHistoryManager(repository: repo)
        let engine = MockHistoryEngine()

        let url = URL(string: "https://example.com/keep.zip")!
        let task = DownloadTaskModel(url: url, filename: "keep.zip", status: .downloading)
        engine.emit([task])
        manager.startObserving(engine: engine)

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.originalURL, url)

        // Task deleted from the Downloads list — the history record must survive.
        engine.emit([])
        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.filename, "keep.zip")

        // Explicit user delete removes it (and persists).
        manager.remove(id: task.id)
        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertTrue(repo.loadHistory().isEmpty)
    }

    @MainActor
    func testHistoryManagerUpsertsByStableID() {
        let repo = DownloadRepository()
        let manager = DownloadHistoryManager(repository: repo)
        let engine = MockHistoryEngine()

        let url = URL(string: "https://example.com/same.zip")!
        let task1 = DownloadTaskModel(url: url, filename: "same.zip", status: .downloading)
        engine.emit([task1])
        manager.startObserving(engine: engine)

        // Same UUID with updated state — must update, not duplicate.
        var task2 = task1
        task2.status = .completed
        task2.completedAt = Date()
        engine.emit([task2])

        XCTAssertEqual(manager.entries.count, 1, "Repeated syncs must never duplicate records")
        XCTAssertEqual(manager.entries.first?.status, .completed)
        XCTAssertNotNil(manager.entries.first?.completedAt)
    }
}

// MARK: - MockHistoryEngine

private final class MockHistoryEngine: DownloadEngineProtocol {
    var tasksPublisher: AnyPublisher<[DownloadTaskModel], Never> { subject.eraseToAnyPublisher() }
    var tasks: [DownloadTaskModel] { _tasks }
    var session: URLSession { URLSession.shared }

    private let subject = PassthroughSubject<[DownloadTaskModel], Never>()
    private var _tasks: [DownloadTaskModel] = []

    func emit(_ tasks: [DownloadTaskModel]) {
        _tasks = tasks
        subject.send(tasks)
    }

    @discardableResult
    func startDownload(url: URL, filename: String?) -> UUID { UUID() }
    func pauseDownload(id: UUID) {}
    func resumeDownload(id: UUID) {}
    func cancelDownload(id: UUID) {}
    func retryDownload(id: UUID) {}
    func deleteDownload(id: UUID, deleteFile: Bool) {}
    func resetToPaused(taskId: UUID) async {}
    func changePriority(for taskId: UUID, to newPriority: DownloadPriority) {}
    func moveTask(from sourceIndex: Int, to destinationIndex: Int) {}
    func updateURL(_ newURL: URL, for id: UUID) {}
}
