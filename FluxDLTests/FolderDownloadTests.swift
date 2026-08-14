import XCTest
@testable import FluxDL

final class FolderDownloadTests: XCTestCase {

    // MARK: - Snapshot aggregation

    func testFolderGroupSnapshotByteWeightedAggregate() {
        let group = DownloadFolderGroup(
            name: "Movie",
            rootURL: URL(string: "https://example.com/Movie/")!,
            destinationDirectoryPath: "/tmp/Downloads/Movie",
            children: [
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/a.mkv")!, filename: "a.mkv", relativePath: "a.mkv", expectedSize: 900),
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/Extras/b.mp4")!, filename: "b.mp4", relativePath: "Extras/b.mp4", expectedSize: 100),
            ]
        )

        var taskA = DownloadTaskModel(url: group.children[0].url, filename: "a.mkv", status: .downloading)
        taskA.downloadedBytes = 450
        taskA.totalBytes = 0
        var taskB = DownloadTaskModel(url: group.children[1].url, filename: "b.mp4", status: .completed)
        taskB.downloadedBytes = 100
        taskB.totalBytes = 100

        let snapshot = FolderGroupSnapshot(group: group, tasks: [taskA, taskB])

        XCTAssertEqual(snapshot.fileCount, 2)
        // expectedSize from the scan wins before a task reports its size
        XCTAssertEqual(snapshot.totalBytes, 1000)
        XCTAssertEqual(snapshot.downloadedBytes, 550)
        XCTAssertEqual(snapshot.progress, 0.55, accuracy: 0.0001)
        XCTAssertEqual(snapshot.completedCount, 1)
        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.unknownSizeCount, 0)
        XCTAssertEqual(snapshot.state, .downloading)
    }

    func testFolderGroupSnapshotUsesReportedSizeWhenLarger() {
        let group = DownloadFolderGroup(
            name: "Movie",
            rootURL: URL(string: "https://example.com/Movie/")!,
            destinationDirectoryPath: "/tmp/Downloads/Movie",
            children: [
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/a.mkv")!, filename: "a.mkv", relativePath: "a.mkv", expectedSize: 100),
            ]
        )
        var task = DownloadTaskModel(url: group.children[0].url, filename: "a.mkv", status: .downloading)
        task.downloadedBytes = 500
        task.totalBytes = 1000

        let snapshot = FolderGroupSnapshot(group: group, tasks: [task])
        XCTAssertEqual(snapshot.totalBytes, 1000, "The engine-reported size wins when it exceeds the scan metadata")
    }

    func testFolderGroupSnapshotUnknownSizeWhenNoMetadata() {
        let group = DownloadFolderGroup(
            name: "Movie",
            rootURL: URL(string: "https://example.com/Movie/")!,
            destinationDirectoryPath: "/tmp/Downloads/Movie",
            children: [
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/a")!, filename: "a", relativePath: "a", expectedSize: nil),
            ]
        )
        var task = DownloadTaskModel(url: group.children[0].url, filename: "a", status: .downloading)
        task.downloadedBytes = 0

        let snapshot = FolderGroupSnapshot(group: group, tasks: [task])
        XCTAssertEqual(snapshot.unknownSizeCount, 1)
        XCTAssertEqual(snapshot.totalBytes, 0)
        XCTAssertEqual(snapshot.progress, 0)
    }

    // MARK: - State derivation

    func testFolderGroupStateDerivation() {
        let url = URL(string: "https://example.com/Movie/")!
        func task(_ status: DownloadStatus) -> DownloadTaskModel {
            DownloadTaskModel(url: url, filename: "f", status: status)
        }

        let allCompleted = FolderGroupSnapshot.deriveState(
            completed: 3, failed: 0, downloading: 0, pending: 0, paused: 0, cancelled: 0, totalChildren: 3)
        XCTAssertEqual(allCompleted, .completed)

        let downloadingDominates = FolderGroupSnapshot.deriveState(
            completed: 1, failed: 1, downloading: 1, pending: 0, paused: 0, cancelled: 0, totalChildren: 3)
        XCTAssertEqual(downloadingDominates, .downloading)

        let queued = FolderGroupSnapshot.deriveState(
            completed: 0, failed: 0, downloading: 0, pending: 2, paused: 0, cancelled: 0, totalChildren: 2)
        XCTAssertEqual(queued, .queued)

        let partiallyCompleted = FolderGroupSnapshot.deriveState(
            completed: 2, failed: 1, downloading: 0, pending: 0, paused: 0, cancelled: 0, totalChildren: 3)
        XCTAssertEqual(partiallyCompleted, .partiallyCompleted)

        let allFailed = FolderGroupSnapshot.deriveState(
            completed: 0, failed: 2, downloading: 0, pending: 0, paused: 0, cancelled: 0, totalChildren: 2)
        XCTAssertEqual(allFailed, .failed)

        let cancelled = FolderGroupSnapshot.deriveState(
            completed: 0, failed: 0, downloading: 0, pending: 0, paused: 0, cancelled: 1, totalChildren: 1)
        XCTAssertEqual(cancelled, .cancelled)

        let paused = FolderGroupSnapshot.deriveState(
            completed: 0, failed: 0, downloading: 0, pending: 0, paused: 2, cancelled: 0, totalChildren: 2)
        XCTAssertEqual(paused, .paused)
    }

    // MARK: - Filter semantics

    func testFolderGroupFilterSemantics() {
        let group = DownloadFolderGroup(
            name: "Movie",
            rootURL: URL(string: "https://example.com/Movie/")!,
            destinationDirectoryPath: "/tmp/Downloads/Movie",
            children: [
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/a")!, filename: "a", relativePath: "a", expectedSize: nil),
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/b")!, filename: "b", relativePath: "b", expectedSize: nil),
            ]
        )
        var taskA = DownloadTaskModel(url: group.children[0].url, filename: "a", status: .downloading)
        taskA.downloadedBytes = 10
        var taskB = DownloadTaskModel(url: group.children[1].url, filename: "b", status: .pending)
        taskB.downloadedBytes = 0

        let snapshot = FolderGroupSnapshot(group: group, tasks: [taskA, taskB])

        XCTAssertTrue(snapshot.matchesFilter(.all))
        XCTAssertTrue(snapshot.matchesFilter(.active), "Any child downloading → Active")
        XCTAssertTrue(snapshot.matchesFilter(.waiting), "Any child pending → Waiting")
        XCTAssertFalse(snapshot.matchesFilter(.paused))
        XCTAssertFalse(snapshot.matchesFilter(.failed))
        XCTAssertFalse(snapshot.matchesFilter(.completed), "Not all children completed")
        XCTAssertFalse(snapshot.matchesFilter(.cancelled))
    }

    func testFolderGroupCompletedFilterRequiresAllChildren() {
        let group = DownloadFolderGroup(
            name: "Movie",
            rootURL: URL(string: "https://example.com/Movie/")!,
            destinationDirectoryPath: "/tmp/Downloads/Movie",
            children: [
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/a")!, filename: "a", relativePath: "a", expectedSize: nil),
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/b")!, filename: "b", relativePath: "b", expectedSize: nil),
            ]
        )
        let taskA = DownloadTaskModel(url: group.children[0].url, filename: "a", status: .completed)
        let taskB = DownloadTaskModel(url: group.children[1].url, filename: "b", status: .completed)

        let snapshot = FolderGroupSnapshot(group: group, tasks: [taskA, taskB])
        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertTrue(snapshot.matchesFilter(.completed))
    }

    // MARK: - Display item filter + sort

    func testApplyFilterAndSortItemsFiltersFoldersAndTasks() {
        let group = DownloadFolderGroup(
            name: "Movie",
            rootURL: URL(string: "https://example.com/Movie/")!,
            destinationDirectoryPath: "/tmp/Downloads/Movie",
            children: [
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/a")!, filename: "a", relativePath: "a", expectedSize: nil),
            ]
        )
        let child = DownloadTaskModel(url: group.children[0].url, filename: "a", status: .downloading)
        let standalone = DownloadTaskModel(url: URL(string: "https://example.com/solo.zip")!, filename: "solo.zip", status: .completed)

        let snapshot = FolderGroupSnapshot(group: group, tasks: [child])
        let items: [DownloadDisplayItem] = [.task(standalone), .folder(snapshot)]

        let active = applyFilterAndSortItems(items, state: DownloadFilterState(filter: .active))
        XCTAssertEqual(active.count, 1)
        if case .folder = active[0] {} else { XCTFail("Folder group should match Active via its downloading child") }

        let completed = applyFilterAndSortItems(items, state: DownloadFilterState(filter: .completed))
        XCTAssertEqual(completed.count, 1)
        if case .task = completed[0] {} else { XCTFail("Standalone completed task should match Completed") }

        let allByName = applyFilterAndSortItems(
            items,
            state: DownloadFilterState(filter: .all, sortKey: .name, direction: .ascending)
        )
        XCTAssertEqual(allByName.count, 2)
        XCTAssertEqual(allByName[0].id, snapshot.id, "Folder sorts before 'solo.zip' ascending by name")
    }

    // MARK: - Duplicate-root normalization

    func testNormalizedRootDeduplicatesEquivalentURLs() {
        let a = URL(string: "https://Example.com/Movies")!
        let b = URL(string: "https://example.com/Movies/")!
        let c = URL(string: "http://example.com/movies/")!

        XCTAssertEqual(FolderDownloadCoordinator.normalizedRoot(a), FolderDownloadCoordinator.normalizedRoot(b),
                       "Trailing slash and host case must not defeat dedup")
        XCTAssertNotEqual(FolderDownloadCoordinator.normalizedRoot(a), FolderDownloadCoordinator.normalizedRoot(c),
                          "Scheme and path case remain significant")
    }

    // MARK: - Codable

    func testDownloadTaskModelCodablePreservesFolderFields() throws {
        let task = DownloadTaskModel(
            url: URL(string: "https://example.com/Movie/Extras/t.mp4")!,
            filename: "t.mp4",
            status: .downloading,
            folderGroupID: UUID(),
            relativePath: "Extras/t.mp4",
            destinationDirectoryPath: "/tmp/Downloads/Movie"
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(DownloadTaskModel.self, from: data)

        XCTAssertEqual(decoded.id, task.id)
        XCTAssertEqual(decoded.folderGroupID, task.folderGroupID)
        XCTAssertEqual(decoded.relativePath, task.relativePath)
        XCTAssertEqual(decoded.destinationDirectoryPath, task.destinationDirectoryPath)
    }

    func testDownloadTaskModelDecodesLegacyPayloadWithoutFolderFields() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","url":"https://example.com/a.zip","filename":"a.zip","status":"completed"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DownloadTaskModel.self, from: legacy)
        XCTAssertNil(decoded.folderGroupID)
        XCTAssertNil(decoded.relativePath)
        XCTAssertNil(decoded.destinationDirectoryPath)
    }

    func testDownloadFolderGroupCodableRoundTrip() throws {
        let group = DownloadFolderGroup(
            name: "Movie",
            rootURL: URL(string: "https://example.com/Movie/")!,
            destinationDirectoryPath: "/tmp/Downloads/Movie",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            children: [
                FolderGroupChild(taskID: UUID(), url: URL(string: "https://example.com/Movie/a.mkv")!, filename: "a.mkv", relativePath: "Extras/a.mkv", expectedSize: 42),
            ]
        )

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(DownloadFolderGroup.self, from: data)

        XCTAssertEqual(decoded.id, group.id)
        XCTAssertEqual(decoded.name, group.name)
        XCTAssertEqual(decoded.destinationDirectoryPath, group.destinationDirectoryPath)
        XCTAssertEqual(decoded.children.count, 1)
        XCTAssertEqual(decoded.children[0].relativePath, "Extras/a.mkv")
        XCTAssertEqual(decoded.children[0].expectedSize, 42)
        XCTAssertEqual(decoded.createdAt, group.createdAt)
    }

    // MARK: - Path sanitization

    func testSanitizedPathComponentNeutralizesTraversal() {
        XCTAssertEqual(FileManagementService.sanitizedPathComponent(".."), "_")
        XCTAssertEqual(FileManagementService.sanitizedPathComponent("."), "_")
        XCTAssertEqual(FileManagementService.sanitizedPathComponent("/"), "_")
        XCTAssertEqual(FileManagementService.sanitizedPathComponent("a/b"), "a_b")
        XCTAssertEqual(FileManagementService.sanitizedPathComponent(""), "_")
        XCTAssertEqual(FileManagementService.sanitizedPathComponent("a: b"), "a_ b")
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(FileManagementService.sanitizedPathComponent(long).count, 150)
    }
}
