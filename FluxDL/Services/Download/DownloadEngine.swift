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

    private lazy var sessionConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsExpensiveNetworkAccess = DownloadsPreferences.shared.allowsCellular
        return configuration
    }()

    private lazy var session: URLSession = {
        URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
    }()

    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var lastWriteTracker: [UUID: (time: TimeInterval, bytes: Int64)] = [:]
    private var retryCounts: [UUID: Int] = [:]
    private var backgroundSessionCompletion: [String: () -> Void] = [:]

    private let stateDirectoryURL: URL
    private let stateFileURL: URL
    private let resumeDataFolderURL: URL
    private let fileManager = FileManager.default

    private override init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        stateDirectoryURL = applicationSupport.appendingPathComponent("Downloads", isDirectory: true)
        stateFileURL = stateDirectoryURL.appendingPathComponent("downloads.json")
        resumeDataFolderURL = stateDirectoryURL.appendingPathComponent("ResumeData", isDirectory: true)

        super.init()

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
        guard !items.contains(where: { $0.url == url.absoluteString }) else { return nil }

        var item = DownloadItem.make(url: url, filename: Self.fallbackFilename(for: url))
        if let queryName = Self.queryFilename(from: url) {
            item.filename = queryName
        }
        item.status = .queued
        items.insert(item, at: 0)
        saveItems()

        Task { [weak self] in
            guard let self else { return }
            let metadata = await self.probeMetadata(for: url)
            DispatchQueue.main.async {
                guard let self else { return }
                if let metadata,
                   let index = self.items.firstIndex(where: { $0.id == item.id })
                {
                    self.items[index].filename = metadata.filename
                    if metadata.totalBytes > 0 {
                        self.items[index].totalBytes = metadata.totalBytes
                    }
                    self.saveItems()
                }
                self.startNextQueuedIfPossible()
            }
        }

        startNextQueuedIfPossible()
        return items.first { $0.id == item.id }
    }

    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        if let task = tasks.removeValue(forKey: id) {
            items[index].status = .paused
            items[index].speed = 0
            saveItems()
            task.cancel { [weak self] resumeData in
                DispatchQueue.main.async {
                    guard let self,
                          let index = self.items.firstIndex(where: { $0.id == id })
                    else { return }

                    self.items[index].speed = 0
                    if let resumeData,
                       (try? resumeData.write(to: self.resumeDataURL(for: id))) != nil
                    {
                        self.items[index].hasResumeData = true
                    }
                    self.saveItems()
                }
            }
        } else if items[index].status == .queued {
            items[index].status = .paused
            saveItems()
        }
    }

    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              [.paused, .failed, .queued].contains(items[index].status)
        else { return }

        items[index].status = .queued
        items[index].errorMessage = nil
        saveItems()
        startNextQueuedIfPossible()
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        tasks[id]?.cancel()
        tasks[id] = nil
        lastWriteTracker[id] = nil
        retryCounts.removeValue(forKey: id)
        items[index].status = .cancelled
        items[index].speed = 0
        deleteResumeData(for: id)
        saveItems()
    }

    func remove(_ id: UUID, deleteFile: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        tasks[id]?.cancel()
        tasks[id] = nil
        lastWriteTracker[id] = nil
        retryCounts.removeValue(forKey: id)
        deleteResumeData(for: id)

        if deleteFile {
            deleteDownloadedFile(for: id)
        }

        items.remove(at: index)
        saveItems()
    }

    func refresh(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let url = URL(string: items[index].url)
        else { return }

        Task { [weak self] in
            guard let self else { return }
            let metadata = await self.probeMetadata(for: url)
            DispatchQueue.main.async {
                guard let self else { return }
                if let metadata,
                   let index = self.items.firstIndex(where: { $0.id == id })
                {
                    self.items[index].filename = metadata.filename
                    if metadata.totalBytes > 0 {
                        self.items[index].totalBytes = metadata.totalBytes
                    }
                    self.saveItems()
                }
                self.resume(id)
            }
        }
    }

    func updateLink(_ id: UUID, to newURL: URL) -> Bool {
        guard let scheme = newURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status != .completed
        else { return false }

        tasks[id]?.cancel()
        tasks[id] = nil
        lastWriteTracker[id] = nil
        retryCounts.removeValue(forKey: id)
        deleteResumeData(for: id)

        var updated = items[index]
        updated.url = newURL.absoluteString
        updated.filename = Self.fallbackFilename(for: newURL)
        if let queryName = Self.queryFilename(from: newURL) {
            updated.filename = queryName
        }
        updated.status = .queued
        updated.bytesReceived = 0
        updated.totalBytes = 0
        updated.speed = 0
        updated.errorMessage = nil
        updated.hasResumeData = false
        updated.downloadedFilename = nil
        items[index] = updated
        saveItems()

        Task { [weak self] in
            guard let self else { return }
            let metadata = await self.probeMetadata(for: newURL)
            DispatchQueue.main.async {
                guard let self else { return }
                if let metadata,
                   let index = self.items.firstIndex(where: { $0.id == id })
                {
                    self.items[index].filename = metadata.filename
                    if metadata.totalBytes > 0 {
                        self.items[index].totalBytes = metadata.totalBytes
                    }
                    self.saveItems()
                }
                self.startNextQueuedIfPossible()
            }
        }

        startNextQueuedIfPossible()
        return true
    }

    func clearCompleted() {
        let previousCount = items.count
        items.removeAll { $0.status == .completed }
        if items.count != previousCount {
            saveItems()
        }
    }

    func applyCellularPreference() {
        sessionConfiguration.allowsExpensiveNetworkAccess = DownloadsPreferences.shared.allowsCellular
    }

    // MARK: - Queue

    private var maxActiveDownloads: Int {
        max(1, DownloadsPreferences.shared.maxActiveDownloads)
    }

    private func startNextQueuedIfPossible() {
        guard !items.isEmpty else { return }

        while tasks.count < maxActiveDownloads,
              let index = items.firstIndex(where: { $0.status == .queued })
        {
            startDownload(at: index)
        }
    }

    private func startDownload(at index: Int) {
        let item = items[index]
        guard let url = URL(string: item.url), tasks[item.id] == nil else { return }

        let task: URLSessionDownloadTask
        if item.hasResumeData, let resumeData = loadResumeData(for: item.id) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = item.id.uuidString
        tasks[item.id] = task
        items[index].status = .downloading
        items[index].errorMessage = nil
        saveItems()
        task.resume()
    }

    // MARK: - Metadata probing

    private struct FileMetadata {
        let filename: String
        let totalBytes: Int64
    }

    private lazy var probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private func probeMetadata(for url: URL) async -> FileMetadata? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        if let (_, response) = try? await probeSession.data(for: request),
           let http = response as? HTTPURLResponse
        {
            return FileMetadata(
                filename: Self.filename(from: http) ?? Self.fallbackFilename(for: url),
                totalBytes: http.expectedContentLength > 0 ? http.expectedContentLength : 0
            )
        }

        // Some servers reject HEAD - fall back to a ranged GET of a single byte
        var rangeRequest = URLRequest(url: url)
        rangeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let (_, response) = try? await probeSession.data(for: rangeRequest),
           let http = response as? HTTPURLResponse
        {
            return FileMetadata(
                filename: Self.filename(from: http) ?? Self.fallbackFilename(for: url),
                totalBytes: http.expectedContentLength > 0 ? http.expectedContentLength : 0
            )
        }
        return nil
    }

    private static func filename(from http: HTTPURLResponse) -> String? {
        guard let disposition = http.value(forHTTPHeaderField: "Content-Disposition")
        else { return nil }

        return filename(fromDisposition: disposition)
    }

    private static func filename(fromDisposition disposition: String) -> String? {
        // RFC 5987: filename*=UTF-8''encoded-name
        if let range = disposition.range(of: "filename\\*=[^;]+", options: .regularExpression) {
            let raw = String(disposition[range]).replacingOccurrences(of: "filename*=", with: "")
            let value = raw.split(separator: "'", maxSplits: 2).last.map(String.init) ?? raw
            return value.removingPercentEncoding ?? value
        }
        // filename="name with spaces.ext"
        if let range = disposition.range(of: "filename=\"[^\"]*\"", options: .regularExpression) {
            let raw = String(disposition[range])
            let value = raw.replacingOccurrences(of: "filename=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
            return value
        }
        // filename=plain.ext
        if let range = disposition.range(of: "filename=[^;]+", options: .regularExpression) {
            return String(disposition[range]).replacingOccurrences(of: "filename=", with: "")
        }
        return nil
    }

    private static func queryFilename(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else { return nil }

        for item in queryItems {
            let name = item.name.lowercased()
            if name == "filename",
               let value = item.value?.removingPercentEncoding,
               !value.isEmpty
            {
                return value
            }
            // R2 Cloudflare: response-content-disposition=attachment; filename="file.ext"
            if name == "response-content-disposition",
               let value = item.value?.removingPercentEncoding,
               let parsed = filename(fromDisposition: value)
            {
                return parsed
            }
            if name == "content-disposition",
               let value = item.value?.removingPercentEncoding,
               let parsed = filename(fromDisposition: value)
            {
                return parsed
            }
        }
        return nil
    }

    private static func fallbackFilename(for url: URL) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last != "/", last.lowercased() != "download" {
            return last
        }
        return "download"
    }

    // MARK: - Auto retry

    private static let maxRetryAttempts = 3

    private func handleRetry(for id: UUID) {
        guard DownloadsPreferences.shared.autoRetryFailed else { return }
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .failed
        else { return }

        let attempt = (retryCounts[id] ?? 0) + 1
        guard attempt <= Self.maxRetryAttempts else {
            retryCounts.removeValue(forKey: id)
            return
        }

        retryCounts[id] = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == id }),
                  [.failed, .paused, .queued].contains(self.items[index].status)
            else { return }

            self.items[index].status = .queued
            self.items[index].errorMessage = nil
            self.saveItems()
            self.startNextQueuedIfPossible()
        }
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

    private func loadResumeData(for id: UUID) -> Data? {
        try? Data(contentsOf: resumeDataURL(for: id))
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

            self.tasks[id] = nil
            self.lastWriteTracker[id] = nil
            self.retryCounts.removeValue(forKey: id)

            let filename = suggestedFilename.isEmpty ? self.items[index].filename : suggestedFilename
            let destination = self.destinationURL(for: filename)

            do {
                try self.fileManager.moveItem(at: location, to: destination)
                self.items[index].downloadedFilename = destination.lastPathComponent
                self.items[index].status = .completed
                self.items[index].errorMessage = nil
                if self.items[index].totalBytes > 0 {
                    self.items[index].bytesReceived = self.items[index].totalBytes
                }
                self.deleteResumeData(for: id)
            } catch {
                self.items[index].status = .failed
                self.items[index].errorMessage = error.localizedDescription
                self.handleRetry(for: id)
            }

            self.items[index].speed = 0
            self.saveItems()
            self.startNextQueuedIfPossible()
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
            if totalBytesExpectedToWrite > 0 {
                self.items[index].totalBytes = totalBytesExpectedToWrite
            }
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
            self.lastWriteTracker[id] = nil

            guard let error = error as NSError? else {
                // Finished without a file (some servers) - treat as failure
                if ![.completed, .failed].contains(self.items[index].status) {
                    self.items[index].status = .failed
                    self.items[index].errorMessage = "Download failed"
                    self.handleRetry(for: id)
                }
                self.saveItems()
                self.startNextQueuedIfPossible()
                return
            }

            if error.code == NSURLErrorCancelled {
                if self.items[index].status == .downloading {
                    self.items[index].status = .paused
                }
                self.items[index].speed = 0
                self.saveItems()
                return
            }

            if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               (try? resumeData.write(to: self.resumeDataURL(for: id))) != nil
            {
                self.items[index].hasResumeData = true
                self.items[index].status = .paused
                self.items[index].errorMessage = nil
            } else {
                self.items[index].status = .failed
                self.items[index].errorMessage = error.localizedDescription
            }

            self.items[index].speed = 0
            self.saveItems()

            if self.items[index].status == .failed {
                self.handleRetry(for: id)
            }
            self.startNextQueuedIfPossible()
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
