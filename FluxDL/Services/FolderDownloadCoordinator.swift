import Foundation
import Combine

/// Orchestrates folder download groups without owning any networking.
///
/// The existing `DownloadEngine` remains the sole owner of actual file
/// downloading (concurrency, pause/resume/retry, proxy routing, background
/// sessions, persistence of tasks). This coordinator only manages:
///
/// - group records (metadata + planned children) and their persistence
/// - submission of child download requests to the existing engine
/// - group-level actions (pause / resume / retry / cancel / remove) which
///   delegate straight to the engine's per-task APIs
/// - byte-weighted aggregate snapshots derived from child task state
@MainActor
public final class FolderDownloadCoordinator: ObservableObject {

    @Published public private(set) var groups: [DownloadFolderGroup] = []

    private let engine: DownloadEngine
    private let repository: DownloadRepositoryProtocol
    private let fileManagerService: FileManagementServiceProtocol

    public init(
        engine: DownloadEngine,
        repository: DownloadRepositoryProtocol,
        fileManagerService: FileManagementServiceProtocol
    ) {
        self.engine = engine
        self.repository = repository
        self.fileManagerService = fileManagerService
        self.groups = repository.loadFolderGroups()
    }

    // MARK: - Snapshots

    /// Byte-weighted aggregate computed from the current engine tasks.
    public func snapshot(for group: DownloadFolderGroup) -> FolderGroupSnapshot {
        FolderGroupSnapshot(group: group, tasks: engine.tasks)
    }

    public func snapshot(id: UUID) -> FolderGroupSnapshot? {
        guard let group = groups.first(where: { $0.id == id }) else { return nil }
        return snapshot(for: group)
    }

    // MARK: - Create

    /// Submits a folder download: one child task per file through the
    /// existing DownloadEngine, preserving the scanned hierarchy through
    /// `relativePath`. Returns false when the folder is empty or an
    /// identical folder download is already active.
    @discardableResult
    public func startFolderDownload(folderName: String, rootURL: URL, files: [CrawledFile]) -> Bool {
        guard !files.isEmpty else { return false }
        guard existingGroup(forRoot: rootURL) == nil else { return false }

        let destinationDirectory = fileManagerService.folderDestinationURL(for: folderName)
        let groupID = UUID()
        var children: [FolderGroupChild] = []
        children.reserveCapacity(files.count)

        for file in files {
            let relativePath = file.relativePath.isEmpty ? file.name : file.relativePath
            let taskID = engine.startDownload(
                url: file.url,
                filename: file.name,
                folderGroupID: groupID,
                relativePath: relativePath,
                destinationDirectoryPath: destinationDirectory.path
            )
            children.append(FolderGroupChild(
                taskID: taskID,
                url: file.url,
                filename: file.name,
                relativePath: relativePath,
                expectedSize: file.sizeBytes
            ))
        }

        let group = DownloadFolderGroup(
            id: groupID,
            name: folderName,
            rootURL: rootURL,
            destinationDirectoryPath: destinationDirectory.path,
            children: children
        )
        groups.insert(group, at: 0)
        repository.saveFolderGroups(groups)
        return true
    }

    // MARK: - Duplicate detection

    /// Stable identity: normalized scheme + host (+ port) + normalized path,
    /// so trailing slashes, case and empty segments cannot create duplicates.
    public static func normalizedRoot(_ url: URL) -> String {
        var host = url.host?.lowercased() ?? ""
        if let port = url.port { host += ":\(port)" }
        var path = url.path
        if !path.hasSuffix("/") { path += "/" }
        return (url.scheme?.lowercased() ?? "") + "://" + host + path
    }

    public func existingGroup(forRoot rootURL: URL) -> DownloadFolderGroup? {
        let normalized = Self.normalizedRoot(rootURL)
        return groups.first { Self.normalizedRoot($0.rootURL) == normalized }
    }

    /// True when a group for the root is still meaningful (not fully
    /// finished), i.e. starting it again would create a duplicate.
    public func hasActiveGroup(forRoot rootURL: URL) -> Bool {
        guard let group = existingGroup(forRoot: rootURL) else { return false }
        switch snapshot(for: group).state {
        case .completed, .failed, .cancelled: return false
        default: return true
        }
    }

    // MARK: - Group-level actions (delegate to the existing engine)

    public func pauseFolder(id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        for child in group.children where isActive(child.taskID) {
            engine.pauseDownload(id: child.taskID)
        }
    }

    public func resumeFolder(id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        for child in group.children where isPaused(child.taskID) {
            engine.resumeDownload(id: child.taskID)
        }
    }

    public func retryFailedFolder(id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        for child in group.children where isRetryable(child.taskID) {
            engine.retryDownload(id: child.taskID)
        }
    }

    public func cancelFolder(id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        for child in group.children where isCancellable(child.taskID) {
            engine.cancelDownload(id: child.taskID)
        }
    }

    /// Removes the group. Every child task is handled through the existing
    /// engine API (which stops the URLSession task and, per `deleteFiles`,
    /// removes the local file). Unrelated downloads are never touched.
    public func removeFolder(id: UUID, deleteFiles: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups[index]
        for child in group.children {
            engine.deleteDownload(id: child.taskID, deleteFile: deleteFiles)
        }
        if deleteFiles {
            fileManagerService.removeFolderDownloadDirectory(
                at: URL(fileURLWithPath: group.destinationDirectoryPath, isDirectory: true)
            )
        }
        groups.remove(at: index)
        repository.saveFolderGroups(groups)
    }

    // MARK: - Child actions

    /// Detaches a child from its folder group. The child task itself stays
    /// in Downloads as a normal standalone download (its physical file is
    /// never touched).
    public func removeChild(taskID: UUID, from groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        engine.mutateTask(id: taskID) { task in
            task.folderGroupID = nil
            task.relativePath = nil
            task.destinationDirectoryPath = nil
        }
        groups[groupIndex].children.removeAll { $0.taskID == taskID }
        repository.saveFolderGroups(groups)
    }

    /// Drops groups whose children no longer exist (e.g. every child task
    /// was removed outside the group flow). Keeps storage tidy without
    /// touching anything else.
    public func pruneEmptyGroups() {
        let before = groups.count
        groups.removeAll { $0.children.isEmpty }
        if groups.count != before {
            repository.saveFolderGroups(groups)
        }
    }

    // MARK: - Status helpers

    private func taskStatus(_ taskID: UUID) -> DownloadStatus? {
        engine.tasks.first { $0.id == taskID }?.status
    }

    private func isActive(_ taskID: UUID) -> Bool {
        guard let status = taskStatus(taskID) else { return false }
        return status == .downloading || status == .pending
    }

    private func isPaused(_ taskID: UUID) -> Bool {
        taskStatus(taskID) == .paused
    }

    private func isRetryable(_ taskID: UUID) -> Bool {
        guard let status = taskStatus(taskID) else { return false }
        return status == .failed || status == .cancelled
    }

    private func isCancellable(_ taskID: UUID) -> Bool {
        guard let status = taskStatus(taskID) else { return false }
        return status == .downloading || status == .pending || status == .paused
    }
}