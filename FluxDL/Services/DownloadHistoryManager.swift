import Foundation
import Combine

/// Persistent download-history store.
///
/// Subscribes to `DownloadEngine.tasksPublisher` and upserts one history
/// record per download (keyed by the task's stable UUID). Records are never
/// removed by the engine — a download deleted from the Downloads list keeps
/// its history entry until the user explicitly deletes it here.
///
/// History is persisted as JSON inside the same `FluxDL_Metadata` folder used
/// by `DownloadRepository`, so it survives app termination and device reboots.
@MainActor
public final class DownloadHistoryManager: ObservableObject {

    @Published public private(set) var entries: [DownloadHistoryEntry] = []

    private let repository: DownloadRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()
    private var isObserving = false
    private var lastPersistTime: Date = .distantPast

    /// Minor byte-progress saves are throttled to avoid disk churn while a
    /// download is streaming; critical changes always persist immediately.
    private let minorPersistInterval: TimeInterval = 2.0

    public init(repository: DownloadRepositoryProtocol) {
        self.repository = repository
        self.entries = repository.loadHistory()
    }

    /// Begin mirroring engine tasks. Safe to call more than once.
    public func startObserving(engine: DownloadEngineProtocol) {
        guard !isObserving else { return }
        isObserving = true

        // The engine publishes from MainActor; delivery is synchronous so the
        // first sync below is consistent and unit tests stay deterministic.
        engine.tasksPublisher
            .sink { [weak self] tasks in
                self?.sync(tasks: tasks)
            }
            .store(in: &cancellables)

        sync(tasks: engine.tasks)
    }

    /// Remove a single history record (explicit user action only).
    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persistNow()
    }

    /// Remove every history record (explicit user action only).
    public func clearAll() {
        entries.removeAll()
        persistNow()
    }

    // MARK: ── Sync ──────────────────────────────────────────────────────────

    private func sync(tasks: [DownloadTaskModel]) {
        var updated = entries
        var hasCriticalChange = false
        var hasMinorChange = false

        for task in tasks {
            if let idx = updated.firstIndex(where: { $0.id == task.id }) {
                switch updated[idx].update(from: task) {
                case .none:
                    break
                case .minor:
                    hasMinorChange = true
                case .critical:
                    hasCriticalChange = true
                }
            } else {
                updated.insert(DownloadHistoryEntry(task: task), at: 0)
                hasCriticalChange = true
            }
        }

        // Keep newest-first so the History screen needs no sorting of its own.
        updated.sort { $0.dateAdded > $1.dateAdded }

        guard entries != updated else { return }
        entries = updated

        if hasCriticalChange {
            persistNow()
        } else if hasMinorChange {
            persistThrottled()
        }
    }

    // MARK: ── Persistence ───────────────────────────────────────────────────

    private func persistNow() {
        repository.saveHistory(entries)
        lastPersistTime = Date()
    }

    private func persistThrottled() {
        guard Date().timeIntervalSince(lastPersistTime) >= minorPersistInterval else { return }
        persistNow()
    }
}
