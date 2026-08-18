import Foundation

// MARK: - Assistant commands

/// Deterministic commands understood by Flux Assistant. Every command maps to
/// an existing engine API — the assistant never touches arbitrary app state.
public enum DownloadAssistantCommand: Equatable, Sendable {
    case pauseAll
    case resumeAll
    case retryFailed
    case listFailed
    case listCompleted
    case listLargerThan(bytes: Int64)
    case listByExtension(String)
    case listByStatus(String)
    case pauseNamed(String)
    case resumeNamed(String)
    case unknown(String)
}

/// Structured result rendered by the assistant sheet.
public struct DownloadAssistantResult: Equatable, Sendable {
    public let summary: String
    public let items: [String]
    public let icon: String

    public init(summary: String, items: [String] = [], icon: String = "sparkles") {
        self.summary = summary
        self.items = items
        self.icon = icon
    }
}

// MARK: - Parsing

/// Parses free-form user input into a strict command. Purely deterministic —
/// a small dictionary of intents, no AI, no network, no app state access.
public enum DownloadAssistantParser {

    public static func parse(_ utterance: String) -> DownloadAssistantCommand {
        let text = utterance
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty else { return .unknown(utterance) }

        if matchesAny(text, ["pause all", "pause everything", "stop all", "stop everything"]) {
            return .pauseAll
        }
        if matchesAny(text, ["resume all", "continue all", "start all", "restart all"]) {
            return .resumeAll
        }
        if matchesAny(text, ["retry failed", "retry all failed", "try failed again", "restart failed"]) {
            return .retryFailed
        }
        if matchesAny(text, ["show failed", "list failed", "what failed", "failed downloads", "show failures"]) {
            return .listFailed
        }
        if matchesAny(text, ["show completed", "list completed", "completed downloads", "finished downloads", "what's done", "whats done"]) {
            return .listCompleted
        }

        if let bytes = parseSize(text) {
            return .listLargerThan(bytes: bytes)
        }

        if let ext = parseExtension(text) {
            return .listByExtension(ext)
        }

        if let status = parseStatus(text) {
            return .listByStatus(status)
        }

        if let name = parseNamedAction(text, action: "pause") {
            return .pauseNamed(name)
        }
        if let name = parseNamedAction(text, action: "resume") {
            return .resumeNamed(name)
        }

        return .unknown(utterance)
    }

    private static func matchesAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { phrase in
            text == phrase || text.hasPrefix(phrase + " ") || text.contains(" " + phrase + " ")
        }
    }

    /// Sizes like "5gb", "5 gb", "1.5GB", "200mb" (integers or one decimal).
    static func parseSize(_ text: String) -> Int64? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(gb|mb|kb)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange]) else { return nil }
        let unit = text[unitRange].lowercased()
        switch unit {
        case "kb": return Int64(value * 1024)
        case "mb": return Int64(value * 1024 * 1024)
        case "gb": return Int64(value * 1024 * 1024 * 1024)
        default: return nil
        }
    }

    static func parseExtension(_ text: String) -> String? {
        let pattern = #"\.(zip|pdf|mp4|mp3|jpg|jpeg|png|mov|mkv|tar|gz|dmg|exe|iso|txt|docx|xlsx|apk|deb|rpm|7z|rar|webm|avi|flac|wav|svg|gif|json|csv|psd|heic|m4a|aac|ogg|epub|mobi)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let extRange = Range(match.range(at: 1), in: text) else { return nil }
        return text[extRange].lowercased()
    }

    static func parseStatus(_ text: String) -> String? {
        for status in ["failed", "paused", "downloading", "completed", "pending", "cancelled", "waiting"] where text.contains(status) {
            return status
        }
        return nil
    }

    static func parseNamedAction(_ text: String, action: String) -> String? {
        let patterns = [
            "\(action) download ",
            "\(action) the download ",
            "\(action) ",
            "can you \(action) "
        ]
        for prefix in patterns where text.hasPrefix(prefix) {
            let name = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 120 else { continue }
            return name
        }
        return nil
    }
}

// MARK: - Executor

/// Executes a parsed command against the download engine, returning a
/// structured result. Only existing engine APIs are used.
@MainActor
public enum DownloadAssistantExecutor {

    public static func execute(
        _ command: DownloadAssistantCommand,
        engine: any DownloadEngineProtocol
    ) async -> DownloadAssistantResult {
        switch command {
        case .pauseAll:
            let count = pauseAll(engine: engine)
            return DownloadAssistantResult(
                summary: count == 0 ? "Nothing was downloading" : "Paused \(count) download\(count == 1 ? "" : "s")",
                icon: "pause.circle.fill"
            )
        case .resumeAll:
            let count = resumeAll(engine: engine)
            return DownloadAssistantResult(
                summary: count == 0 ? "Nothing was paused" : "Resumed \(count) download\(count == 1 ? "" : "s")",
                icon: "play.circle.fill"
            )
        case .retryFailed:
            let count = retryFailed(engine: engine)
            return DownloadAssistantResult(
                summary: count == 0 ? "No failed downloads to retry" : "Queued \(count) failed download\(count == 1 ? "" : "s") for retry",
                icon: "arrow.clockwise.circle.fill"
            )
        case .listFailed:
            let items = engine.tasks.filter { $0.status == .failed }.map { "• \($0.filename)" }
            return DownloadAssistantResult(
                summary: items.isEmpty ? "No failed downloads" : "\(items.count) failed download\(items.count == 1 ? "" : "s")",
                items: items.prefix(20).map(String.init),
                icon: "exclamationmark.triangle.fill"
            )
        case .listCompleted:
            let items = engine.tasks.filter { $0.status == .completed }.map { "• \($0.filename)" }
            return DownloadAssistantResult(
                summary: items.isEmpty ? "No completed downloads yet" : "\(items.count) completed download\(items.count == 1 ? "" : "s")",
                items: items.prefix(20).map(String.init),
                icon: "checkmark.circle.fill"
            )
        case .listLargerThan(let bytes):
            let items = engine.tasks
                .filter { $0.totalBytes >= bytes }
                .map { "• \($0.filename) (\(ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file)))" }
            return DownloadAssistantResult(
                summary: items.isEmpty ? "Nothing larger than that" : "\(items.count) download\(items.count == 1 ? "" : "s") over \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
                items: items.prefix(20).map(String.init),
                icon: "internaldrive.fill"
            )
        case .listByExtension(let ext):
            let items = engine.tasks
                .filter { $0.filename.lowercased().hasSuffix(".\(ext)") }
                .map { "• \($0.filename)" }
            return DownloadAssistantResult(
                summary: items.isEmpty ? "No .\(ext) downloads" : "\(items.count) .\(ext) download\(items.count == 1 ? "" : "s")",
                items: items.prefix(20).map(String.init),
                icon: "doc.fill"
            )
        case .listByStatus(let status):
            let items = engine.tasks
                .filter { $0.status.rawValue.lowercased() == status }
                .map { "• \($0.filename)" }
            return DownloadAssistantResult(
                summary: items.isEmpty ? "No \(status) downloads" : "\(items.count) \(status) download\(items.count == 1 ? "" : "s")",
                items: items.prefix(20).map(String.init),
                icon: "list.bullet"
            )
        case .pauseNamed(let name):
            let matches = engine.tasks.filter { $0.status == .downloading && $0.filename.localizedCaseInsensitiveContains(name) }
            for task in matches {
                engine.pauseDownload(id: task.id)
            }
            return DownloadAssistantResult(
                summary: matches.isEmpty ? "No active download matching \"\(name)\"" : "Paused \(matches.count) download\(matches.count == 1 ? "" : "s") matching \"\(name)\"",
                items: matches.map { "• \($0.filename)" },
                icon: "pause.circle.fill"
            )
        case .resumeNamed(let name):
            let matches = engine.tasks.filter { $0.status == .paused && $0.filename.localizedCaseInsensitiveContains(name) }
            for task in matches {
                engine.resumeDownload(id: task.id)
            }
            return DownloadAssistantResult(
                summary: matches.isEmpty ? "No paused download matching \"\(name)\"" : "Resumed \(matches.count) download\(matches.count == 1 ? "" : "s") matching \"\(name)\"",
                items: matches.map { "• \($0.filename)" },
                icon: "play.circle.fill"
            )
        case .unknown(let raw):
            return DownloadAssistantResult(
                summary: "I didn't understand that. Try:",
                items: [
                    "• \"pause all\"",
                    "• \"resume all\"",
                    "• \"retry failed\"",
                    "• \"show failed\"",
                    "• \"show completed\"",
                    "• \"downloads larger than 5 GB\"",
                    "• \"show .zip downloads\"",
                    "• \"pause <name>\""
                ],
                icon: "questionmark.circle"
            )
        }
    }

    private static func pauseAll(engine: any DownloadEngineProtocol) -> Int {
        let active = engine.tasks.filter { $0.status == .downloading }
        for task in active {
            engine.pauseDownload(id: task.id)
        }
        return active.count
    }

    private static func resumeAll(engine: any DownloadEngineProtocol) -> Int {
        let paused = engine.tasks.filter { $0.status == .paused }
        for task in paused {
            engine.resumeDownload(id: task.id)
        }
        return paused.count
    }

    private static func retryFailed(engine: any DownloadEngineProtocol) -> Int {
        let failed = engine.tasks.filter { $0.status == .failed }
        for task in failed {
            engine.retryDownload(id: task.id)
        }
        return failed.count
    }
}