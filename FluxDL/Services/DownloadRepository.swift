import Foundation

public protocol DownloadRepositoryProtocol: AnyObject {
    func loadTasks() -> [DownloadTaskModel]
    func saveTasks(_ tasks: [DownloadTaskModel])
}

public final class DownloadRepository: DownloadRepositoryProtocol {
    private let fileManager = FileManager.default
    private let metadataDirectoryURL: URL
    private let tasksFileURL: URL
    
    public init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        self.metadataDirectoryURL = documents.appendingPathComponent("FluxDL_Metadata", isDirectory: true)
        self.tasksFileURL = metadataDirectoryURL.appendingPathComponent("downloads.json")
        ensureDirectoryExists()
    }
    
    private func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: metadataDirectoryURL.path) {
            try? fileManager.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)
        }
    }
    
    public func loadTasks() -> [DownloadTaskModel] {
        guard fileManager.fileExists(atPath: tasksFileURL.path),
              let data = try? Data(contentsOf: tasksFileURL),
              let tasks = try? JSONDecoder().decode([DownloadTaskModel].self, from: data) else {
            return []
        }
        return tasks
    }
    
    public func saveTasks(_ tasks: [DownloadTaskModel]) {
        ensureDirectoryExists()
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: tasksFileURL, options: .atomic)
        } catch {
            print("Failed to save download tasks metadata: \(error)")
        }
    }
}
