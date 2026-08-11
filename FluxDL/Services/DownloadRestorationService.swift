import Foundation

// MARK: - Protocol

@MainActor
public protocol DownloadRestorationServiceProtocol: AnyObject {
    /// Reconcile persisted task models with live background URLSession tasks.
    /// Call on every app launch before the UI is shown.
    func restoreActiveTasks(engine: DownloadEngine) async
}

// MARK: - Implementation

@MainActor
public final class DownloadRestorationService: DownloadRestorationServiceProtocol {
    
    public init() {}
    
    /// Queries the background URLSession for all in-flight tasks and reconciles
    /// them with the persisted `DownloadTaskModel` records held by the engine.
    ///
    /// - Tasks still running in the background → re-register in delegate dictionaries;
    ///   status stays `.downloading` so in-progress events are routed correctly.
    /// - Tasks that completed while the app was not running → the delegate will handle
    ///   `didFinishDownloadingTo` automatically once re-registered.
    /// - Session tasks with no matching persisted record → cancel (orphaned).
    /// - Persisted `.downloading` records with no matching session task → reset to `.paused`.
    public func restoreActiveTasks(engine: DownloadEngine) async {
        let sessionTasks = await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in
            engine.session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
        
        // Build lookup: taskIdentifier → URLSessionTask
        let liveTaskMap: [Int: URLSessionTask] = Dictionary(
            uniqueKeysWithValues: sessionTasks.map { ($0.taskIdentifier, $0) }
        )
        
        // Walk persisted tasks that were in a "downloading" state
        for task in engine.tasks where task.status == .downloading {
            guard let sessionID = task.sessionTaskIdentifier,
                  let liveTask  = liveTaskMap[sessionID] else {
                // No live session task → system may have been killed; reset to paused
                print("FluxDL Restore: Task \(task.id) has no live session task — resetting to paused.")
                await engine.resetToPaused(taskId: task.id)
                continue
            }
            
            // Confirm URL matches to prevent cross-task collisions
            if let originalURL = liveTask.originalRequest?.url,
               originalURL.absoluteString == task.url.absoluteString {
                print("FluxDL Restore: Re-registering task \(task.id) (sessionID=\(sessionID), state=\(liveTask.state.rawValue)).")
                // CRITICAL: re-register in delegate-queue dictionaries so that
                // subsequent didFinishDownloadingTo / didWriteData callbacks route correctly.
                engine.reregisterRestoredTask(
                    taskId: task.id,
                    sessionTaskIdentifier: sessionID,
                    startBytes: task.downloadedBytes,
                    totalBytes: task.totalBytes
                )
            } else {
                // URL mismatch → orphaned; cancel and reset
                print("FluxDL Restore: Task \(task.id) URL mismatch — cancelling orphan.")
                liveTask.cancel()
                await engine.resetToPaused(taskId: task.id)
            }
        }
        
        // Cancel truly orphaned live tasks that have no persisted record
        let knownSessionIDs = Set(engine.tasks.compactMap { $0.sessionTaskIdentifier })
        for liveTask in sessionTasks where !knownSessionIDs.contains(liveTask.taskIdentifier) {
            print("FluxDL Restore: Cancelling orphaned session task \(liveTask.taskIdentifier).")
            liveTask.cancel()
        }

        // Kick the queue: persisted `.pending` tasks must start as soon as
        // slots free up after relaunch (nothing else will trigger this).
        ServiceContainer.shared.queueManager.scheduleNextTasks(in: engine)
    }
}
