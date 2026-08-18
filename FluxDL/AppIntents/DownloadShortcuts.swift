import Foundation
import AppIntents

// MARK: - Shortcuts / Siri intents (Download tab only)

/// All intents go through the existing engine APIs (`DownloadEngineProtocol`),
/// so Shortcuts and the Download tab share exactly one execution path.
@MainActor
private func engine() -> any DownloadEngineProtocol {
    ServiceContainer.shared.downloadEngine
}

// MARK: Download URL

struct FluxDownloadURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Download URL"
    static let description = IntentDescription("Adds a download to the Downloads tab.")

    @Parameter(title: "URL")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$url)")
    }

    func perform() async throws -> some IntentResult {
        engine().startDownload(url: url, filename: nil)
        return .result()
    }
}

// MARK: Pause one download

struct FluxPauseDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Download"
    static let description = IntentDescription("Pauses one download in the Downloads tab.")

    @Parameter(title: "Filename")
    var filename: String

    static var parameterSummary: some ParameterSummary {
        Summary("Pause \(\.$filename)")
    }

    func perform() async throws -> some IntentResult {
        let target = engine().tasks.first { $0.filename.localizedCaseInsensitiveContains(filename) }
        if let target {
            engine().pauseDownload(id: target.id)
            return .result()
        }
        throw IntentError.notFound
    }
}

// MARK: Resume one download

struct FluxResumeDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Download"
    static let description = IntentDescription("Resumes one download in the Downloads tab.")

    @Parameter(title: "Filename")
    var filename: String

    static var parameterSummary: some ParameterSummary {
        Summary("Resume \(\.$filename)")
    }

    func perform() async throws -> some IntentResult {
        let target = engine().tasks.first { $0.filename.localizedCaseInsensitiveContains(filename) }
        if let target {
            engine().resumeDownload(id: target.id)
            return .result()
        }
        throw IntentError.notFound
    }
}

// MARK: Retry one download

struct FluxRetryDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Retry Download"
    static let description = IntentDescription("Retries a failed download in the Downloads tab.")

    @Parameter(title: "Filename")
    var filename: String

    func perform() async throws -> some IntentResult {
        let target = engine().tasks.first { $0.filename.localizedCaseInsensitiveContains(filename) }
        if let target {
            engine().retryDownload(id: target.id)
            return .result()
        }
        throw IntentError.notFound
    }
}

// MARK: Pause all

struct FluxPauseAllDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause All Downloads"
    static let description = IntentDescription("Pauses every active download.")

    func perform() async throws -> some IntentResult {
        let active = engine().tasks.filter { $0.status == .downloading }
        for task in active {
            engine().pauseDownload(id: task.id)
        }
        return .result(value: "Paused \(active.count) download(s)")
    }
}

// MARK: Resume all

struct FluxResumeAllDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume All Downloads"
    static let description = IntentDescription("Resumes every paused download.")

    func perform() async throws -> some IntentResult {
        let paused = engine().tasks.filter { $0.status == .paused }
        for task in paused {
            engine().resumeDownload(id: task.id)
        }
        return .result(value: "Resumed \(paused.count) download(s)")
    }
}

// MARK: Get status

struct FluxDownloadStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Download Status"
    static let description = IntentDescription("Reports what the Downloads tab is doing.")

    static var parameterSummary: some ParameterSummary { Summary("Get download status") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tasks = engine().tasks
        let active = tasks.filter { $0.status == .downloading }.count
        let paused = tasks.filter { $0.status == .paused }.count
        let failed = tasks.filter { $0.status == .failed }.count
        let completed = tasks.filter { $0.status == .completed }.count
        let dialog = "\(active) downloading, \(paused) paused, \(failed) failed, \(completed) completed."
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: Open Downloads

struct FluxOpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Downloads"
    static let description = IntentDescription("Opens the Downloads tab.")

    func perform() async throws -> some IntentResult {
        // Route the user to the Downloads tab (the tab router listens for
        // this exact notification; wiring is one line, Downloads-only).
        NotificationCenter.default.post(name: .fluxdlOpenDownloadsTab, object: nil)
        return .result()
    }
}

// MARK: Intent error + notification

extension IntentError {
    static let notFound = IntentError.message("No matching download found")
}

extension Notification.Name {
    /// Posted by `FluxOpenDownloadsIntent`; the tab container observes it and
    /// switches to the Downloads tab.
    static let fluxdlOpenDownloadsTab = Notification.Name("fluxdl.open.downloads.tab")
}