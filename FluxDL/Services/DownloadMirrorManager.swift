import Foundation

// MARK: - DownloadMirrorManager

/// Manages mirror URLs for individual download tasks.
/// Runs on MainActor — all mutations are serialised through the DownloadEngine.
@MainActor
public final class DownloadMirrorManager {

    public static let shared = DownloadMirrorManager()

    // Consecutive failure counts per task, used for auto-switching.
    private var consecutiveFailures: [UUID: Int] = [:]
    /// Number of consecutive failures before auto-switching to the next mirror.
    public var autoSwitchThreshold: Int = 3

    // MARK: Public API

    /// Add a mirror URL to a task. Does nothing if the mirror already exists.
    public func addMirror(_ url: URL, to taskID: UUID, engine: DownloadEngine) {
        guard let idx = engine.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard !engine.tasks[idx].mirrors.contains(url),
              url != engine.tasks[idx].url else { return }
        engine.mutateTask(id: taskID) { task in
            task.mirrors.append(url)
        }
    }

    /// Remove a mirror by its index in the mirrors array.
    public func removeMirror(at mirrorIndex: Int, from taskID: UUID, engine: DownloadEngine) {
        guard let idx = engine.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard mirrorIndex < engine.tasks[idx].mirrors.count else { return }
        engine.mutateTask(id: taskID) { task in
            task.mirrors.remove(at: mirrorIndex)
            // If the currently active mirror was removed, fall back to primary
            if task.currentMirrorIndex > task.mirrors.count {
                task.currentMirrorIndex = 0
            }
        }
    }

    /// Manually switch to a specific mirror index (0 = primary URL).
    public func selectMirror(index: Int, for taskID: UUID, engine: DownloadEngine) {
        guard let idx = engine.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let maxIdx = engine.tasks[idx].mirrors.count  // 0…count: 0=primary, 1…count=mirrors
        guard index >= 0 && index <= maxIdx else { return }

        let wasPausedOrFailed = engine.tasks[idx].status == .paused || engine.tasks[idx].status == .failed

        // Compute the target URL on a copy BEFORE `updateURL` resets
        // `currentMirrorIndex` (the new URL owns a fresh mirror state).
        var candidate = engine.tasks[idx]
        candidate.currentMirrorIndex = index
        let activeURL = candidate.activeURL

        // If the task is paused or failed, restart with the new URL
        if wasPausedOrFailed {
            engine.updateURL(activeURL, for: taskID)
            // Re-apply the chosen mirror after the reset, then restart
            // immediately on it instead of leaving the task paused.
            engine.mutateTask(id: taskID) { task in
                task.currentMirrorIndex = index
            }
            if engine.tasks.firstIndex(where: { $0.id == taskID }) != nil {
                engine.resumeDownload(id: taskID)
            }
        } else {
            // Live task: only the active mirror changes; the in-flight
            // download keeps running until its next failure.
            engine.mutateTask(id: taskID) { task in
                task.currentMirrorIndex = index
            }
        }
        consecutiveFailures[taskID] = 0
    }

    /// Called by the engine after a task failure.
    /// Returns `true` if a mirror switch was performed (caller should retry).
    @discardableResult
    public func recordFailure(for taskID: UUID, engine: DownloadEngine) -> Bool {
        let count = (consecutiveFailures[taskID] ?? 0) + 1
        consecutiveFailures[taskID] = count

        guard count >= autoSwitchThreshold else { return false }
        return switchToNextMirror(for: taskID, engine: engine)
    }

    /// Attempt to switch to the next available mirror.
    /// Returns `true` if a switch was performed.
    @discardableResult
    public func switchToNextMirror(for taskID: UUID, engine: DownloadEngine) -> Bool {
        guard let idx = engine.tasks.firstIndex(where: { $0.id == taskID }) else { return false }
        let task = engine.tasks[idx]

        let nextIndex = task.currentMirrorIndex + 1
        guard nextIndex <= task.mirrors.count else {
            // No more mirrors
            consecutiveFailures[taskID] = 0
            return false
        }

        // Resolve the target URL on a copy BEFORE `updateURL` resets
        // `currentMirrorIndex` (the new URL owns a fresh mirror state).
        var nextTask = task
        nextTask.currentMirrorIndex = nextIndex
        let newURL = nextTask.activeURL

        engine.updateURL(newURL, for: taskID)
        engine.mutateTask(id: taskID) { task in
            task.currentMirrorIndex = nextIndex
            task.mirrorSwitchCount += 1
        }
        consecutiveFailures[taskID] = 0
        // updateURL leaves the task paused — the switch must bring it back
        // up immediately or every failed download silently stalls forever.
        if engine.tasks.firstIndex(where: { $0.id == taskID }) != nil {
            engine.resumeDownload(id: taskID)
        }

        print("FluxDL: Auto-switched task \(taskID) to mirror \(nextIndex) → \(newURL)")
        return true
    }

    /// Reset failure counter when a task succeeds.
    public func recordSuccess(for taskID: UUID) {
        consecutiveFailures[taskID] = 0
    }

    /// Remove tracking state when a task is deleted.
    public func removeTask(_ taskID: UUID) {
        consecutiveFailures.removeValue(forKey: taskID)
    }
}