//
//  DownloadEngine.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Combine
import Foundation

final class DownloadEngine: NSObject {
    static let shared = DownloadEngine()

    static let sessionIdentifier = "com.fluxdl.downloads.session"
    static let downloadsFolderName = "Downloads"

    static var downloadsFolderURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(downloadsFolderName, isDirectory: true)
    }

    @Published private(set) var items: [DownloadItem] = []

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var lastWriteTracker: [UUID: (time: TimeInterval, bytes: Int64)] = [:]
    private var backgroundSessionCompletion: [String: () -> Void] = [:]

    private let stateDirectoryURL: URL
    private let stateFileURL: URL
    private let resumeDataFolderURL: URL
    private let fileManager = FileManager.default

    private init() {
        super.init()

        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        stateDirectoryURL = applicationSupport.appendingPathComponent("Downloads", isDirectory: true)
        stateFileURL = stateDirectoryURL.appendingPathComponent("downloads.json")
        resumeDataFolderURL = stateDirectoryURL.appendingPathComponent("ResumeData", isDirectory: true)

        try? fileManager.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resumeDataFolderURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: Self.downloadsFolderURL, withIntermediateDirectories: true)

        loadItems()
        restoreInFlightTasks()
    }

    // MARK: - Public API

    @discardableResult
    func addDownload(from url: URL) -> DownloadItem? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return nil }

        var item = DownloadItem.make(url: url, filename: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        item.status = .downloading

        let task = session.downloadTask(with: url)
        task.taskDescription = item.id.uuidString
        tasks[item.id] = task

        items.insert(item, at: 0)
        saveItems()
        task.resume()

        return item
    }

    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let task = tasks[id],
              items[index].status == .downloading
        else { return }

        task.cancel { [weak self] resumeData in
            DispatchQueue.main.async {
                guard let self,
                      let index = self.items.firstIndex(where: { $0.id == id })
                else { return }

                self.tasks[id] = nil
                self.items[index].status = .paused
                self.items[index].speed = 0

                if let resumeData {
                    if (try? resumeData.write(to: self.resumeDataURL(for: id))) != nil {
                        self.items[index].hasResumeData = true
                    }
                }
                self.saveItems()
            }
        }
    }

    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .paused || items[index].status == .failed || items[index].status == .queued
        else { return }

        let resumeData = try? Data(contentsOf: resumeDataURL(for: id))
        var task: URLSessionDownloadTask?

        if let resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else if let url = URL(string: items[index].url) {
            task = session.downloadTask(with: url)
        }

        guard let task else { return }

        task.taskDescription = id.uuidString
        tasks[id] = task
        items[index].status = .downloading
        items[index].errorMessage = nil
        saveItems()
        task.resume()
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        tasks[id]?.cancel()
        tasks[id] = nil
        items[index].status = .cancelled
        items[index].speed = 0
        deleteResumeData(for: id)
        saveItems()
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        tasks[id]?.cancel()
        tasks[id] = nil
        deleteResumeData(for: id)
        deleteDownloadedFile(for: id)
        items.remove(at: index)
        saveItems()
    }

    // MARK: - Background events

    func handleBackgroundEvents(sessionIdentifier: String, completion: @escaping () -> Void) {
        guard sessionIdentifier == Self.sessionIdentifier else { return }
        backgroundSessionCompletion[sessionIdentifier] = completion
        _ = session
    }

    // MARK: - Persistence

    private func loadItems() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let loaded = try? JSONDecoder().decode([DownloadItem].self, from: data)
        else { return }

        items = loaded
    }

    private func saveItems() {
        guard let data = try? JSONEncoder().encode(items)
        else { return }

        try? data.write(to: stateFileURL, options: .atomic)
    }

    private func deleteResumeData(for id: UUID) {
        try? fileManager.removeItem(at: resumeDataURL(for: id))
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].hasResumeData = false
        }
    }

    private func deleteDownloadedFile(for id: UUID) {
        guard let filename = items.first(where: { $0.id == id })?.downloadedFilename
        else { return }

        try? fileManager.removeItem(at: Self.downloadsFolderURL.appendingPathComponent(filename))
    }

    private func resumeDataURL(for id: UUID) -> URL {
        resumeDataFolderURL.appendingPathComponent("\(id.uuidString).data")
    }

    private func destinationURL(for filename: String) -> URL {
        let ext = (filename as NSString).pathExtension
        let base = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))
        var name = filename
        var candidate = Self.downloadsFolderURL.appendingPathComponent(name)
        var counter = 1

        while fileManager.fileExists(atPath: candidate.path) {
            name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = Self.downloadsFolderURL.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: - Tasks restore

    private func restoreInFlightTasks() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }

                let liveIDs = Set(tasks.compactMap { self.taskID(for: $0) })
                for task in tasks {
                    guard let id = self.taskID(for: task) else { continue }
                    self.tasks[id] = task as? URLSessionDownloadTask
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[index].status = .downloading
                    }
                }

                for index in self.items.indices
                where self.items[index].status == .downloading && !liveIDs.contains(self.items[index].id) {
                    self.items[index].status = .paused
                }

                self.saveItems()
            }
        }
    }

    private func taskID(for task: URLSessionTask) -> UUID? {
        guard let description = task.taskDescription
        else { return nil }

        return UUID(uuidString: description)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadEngine: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = taskID(for: downloadTask) else { return }

        let suggestedFilename = downloadTask.response?.suggestedFilename ?? ""

        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }

            let filename = suggestedFilename.isEmpty ? self.items[index].filename : suggestedFilename
            let destination = self.destinationURL(for: filename)

            do {
                try self.fileManager.moveItem(at: location, to: destination)
                self.items[index].downloadedFilename = destination.lastPathComponent
                self.items[index].status = .completed
                self.items[index].errorMessage = nil
            } catch {
                self.items[index].status = .failed
                self.items[index].errorMessage = error.localizedDescription
            }

            self.items[index].speed = 0
            self.tasks[id] = nil
            self.saveItems()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = taskID(for: downloadTask) else { return }

        let now = Date().timeIntervalSince1970
        var speed: Int64 = 0

        if let last = lastWriteTracker[id] {
            let delta = now - last.time
            if delta >= 0.4 {
                speed = Int64((Double(totalBytesWritten - last.bytes) / delta).rounded())
                lastWriteTracker[id] = (now, totalBytesWritten)
            }
        } else {
            lastWriteTracker[id] = (now, totalBytesWritten)
        }

        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }),
                  self.items[index].status == .downloading
            else { return }

            self.items[index].bytesReceived = totalBytesWritten
            self.items[index].totalBytes = totalBytesExpectedToWrite
            self.items[index].speed = speed

            if self.items[index].filename == "download",
               let suggested = downloadTask.response?.suggestedFilename,
               !suggested.isEmpty
            {
                self.items[index].filename = suggested
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let id = taskID(for: downloadTask)
        else { return }

        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }

            self.tasks[id] = nil

            guard let error = error as NSError? else { return }

            if error.code == NSURLErrorCancelled {
                if self.items[index].status == .downloading {
                    self.items[index].status = .paused
                }
                self.items[index].speed = 0
                self.saveItems()
                return
            }

            if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let _ = try? resumeData.write(to: self.resumeDataURL(for: id))
            {
                self.items[index].hasResumeData = true
                self.items[index].status = .paused
            } else {
                self.items[index].status = .failed
                self.items[index].errorMessage = error.localizedDescription
            }

            self.items[index].speed = 0
            self.saveItems()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        DispatchQueue.main.async {
            let completion = self.backgroundSessionCompletion.removeValue(forKey: identifier)
            completion?()
        }
    }
}