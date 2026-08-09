import Foundation

// MARK: - DownloadBatchManager

/// Executes batch operations on a set of download task IDs.
/// All methods run on the MainActor and delegate to the existing DownloadEngine API.
@MainActor
public final class DownloadBatchManager {

    public static let shared = DownloadBatchManager()

    // MARK: Batch Operations

    public func pauseAll(ids: Set<UUID>, engine: DownloadEngine) {
        for id in ids {
            let task = engine.tasks.first { $0.id == id }
            guard task?.status == .downloading || task?.status == .pending else { continue }
            engine.pauseDownload(id: id)
        }
    }

    public func resumeAll(ids: Set<UUID>, engine: DownloadEngine) {
        for id in ids {
            let task = engine.tasks.first { $0.id == id }
            guard task?.status == .paused || task?.status == .failed else { continue }
            engine.resumeDownload(id: id)
        }
        ServiceContainer.shared.queueManager.scheduleNextTasks(in: engine)
    }

    public func retryAll(ids: Set<UUID>, engine: DownloadEngine) {
        for id in ids {
            let task = engine.tasks.first { $0.id == id }
            guard task?.status == .failed || task?.status == .cancelled else { continue }
            engine.retryDownload(id: id)
        }
        ServiceContainer.shared.queueManager.scheduleNextTasks(in: engine)
    }

    public func cancelAll(ids: Set<UUID>, engine: DownloadEngine) {
        for id in ids {
            let task = engine.tasks.first { $0.id == id }
            guard task?.status == .downloading || task?.status == .pending || task?.status == .paused else { continue }
            engine.cancelDownload(id: id)
        }
    }

    public func deleteAll(ids: Set<UUID>, engine: DownloadEngine, deleteFiles: Bool) {
        // Collect IDs that exist before we start mutating
        let toDelete = ids.filter { id in engine.tasks.contains { $0.id == id } }
        for id in toDelete {
            engine.deleteDownload(id: id, deleteFile: deleteFiles)
        }
        ServiceContainer.shared.queueManager.scheduleNextTasks(in: engine)
    }
}
