import Foundation

public protocol DownloadRepositoryProtocol: AnyObject {
    func loadTasks() -> [DownloadTaskModel]
    func saveTasks(_ tasks: [DownloadTaskModel])
    func loadHistory() -> [DownloadHistoryEntry]
    func saveHistory(_ entries: [DownloadHistoryEntry])
    func loadFolderGroups() -> [DownloadFolderGroup]
    func saveFolderGroups(_ groups: [DownloadFolderGroup])
}

public final class DownloadRepository: DownloadRepositoryProtocol {
    private let fileManager = FileManager.default
    private let metadataDirectoryURL: URL
    private let tasksFileURL: URL
    private let historyFileURL: URL
    private let folderGroupsFileURL: URL
    
    public init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        self.metadataDirectoryURL = documents.appendingPathComponent("FluxDL_Metadata", isDirectory: true)
        self.tasksFileURL = metadataDirectoryURL.appendingPathComponent("downloads.json")
        self.historyFileURL = metadataDirectoryURL.appendingPathComponent("downloadHistory.json")
        self.folderGroupsFileURL = metadataDirectoryURL.appendingPathComponent("folderGroups.json")
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
    
    public func loadHistory() -> [DownloadHistoryEntry] {
        guard fileManager.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL),
              let entries = try? JSONDecoder().decode([DownloadHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }
    
    public func saveHistory(_ entries: [DownloadHistoryEntry]) {
        ensureDirectoryExists()
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("Failed to save download history metadata: \(error)")
        }
    }

    public func loadFolderGroups() -> [DownloadFolderGroup] {
        guard fileManager.fileExists(atPath: folderGroupsFileURL.path),
              let data = try? Data(contentsOf: folderGroupsFileURL),
              let groups = try? JSONDecoder().decode([DownloadFolderGroup].self, from: data) else {
            return []
        }
        return groups
    }

    public func saveFolderGroups(_ groups: [DownloadFolderGroup]) {
        ensureDirectoryExists()
        do {
            let data = try JSONEncoder().encode(groups)
            try data.write(to: folderGroupsFileURL, options: .atomic)
        } catch {
            print("Failed to save folder groups metadata: \(error)")
        }
    }
}
