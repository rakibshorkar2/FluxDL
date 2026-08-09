import Foundation

// MARK: - ChecksumResult

public struct ChecksumResult: Sendable {
    public let taskID: UUID
    public let sha256: String
    public let md5: String
}

// MARK: - DownloadVerificationService

/// Actor-isolated checksum service.
/// Computes SHA-256 and MD5 on a background context; never blocks the MainActor.
public actor DownloadVerificationService {

    public static let shared = DownloadVerificationService()

    // Track in-progress computations so we don't double-compute.
    private var inProgress: Set<UUID> = []

    /// Compute checksums for a completed task and write results back to the engine.
    /// If computation is already in progress for this task, this is a no-op.
    public func computeAndStore(task: DownloadTaskModel, engine: DownloadEngine) async {
        guard !inProgress.contains(task.id) else { return }
        guard let path = task.destinationPath else { return }

        inProgress.insert(task.id)
        defer { inProgress.remove(task.id) }

        let fileURL = URL(fileURLWithPath: path)

        do {
            async let sha256Task = Task.detached(priority: .utility) {
                try ChecksumVerifier.computeHash(for: fileURL, algorithm: .sha256)
            }.value

            async let md5Task = Task.detached(priority: .utility) {
                try ChecksumVerifier.computeHash(for: fileURL, algorithm: .md5)
            }.value

            let (sha256, md5) = try await (sha256Task, md5Task)

            await MainActor.run {
                engine.mutateTask(id: task.id) { task in
                    task.sha256Hash = sha256
                    task.md5Hash    = md5
                }
            }
        } catch {
            print("FluxDL: Checksum computation failed for \(task.filename): \(error)")
        }
    }

    /// Returns true if the task's checksum is currently being computed.
    public func isComputing(taskID: UUID) -> Bool {
        inProgress.contains(taskID)
    }
}
