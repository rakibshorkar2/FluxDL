import Foundation

// MARK: - DiagnosticsReport

public struct DiagnosticsReport: Sendable {
    public let taskID:            UUID
    public let filename:          String
    public let status:            DownloadStatus
    public let errorCode:         Int?
    public let httpStatus:        Int?
    public let networkError:      String?
    public let canResume:         Bool
    public let retryCount:        Int
    public let maxRetries:        Int
    public let failureReason:     String?
    public let lastSuccessfulByte: Int64
    public let rangeSupported:    Bool
    public let suggestedFix:      String
    public let retryHistory:      [RetryRecord]
    public let generatedAt:       Date

    // MARK: Plain-text export

    public var plainText: String {
        var lines: [String] = [
            "═══════════════════════════════",
            "FluxDL Diagnostics Report",
            "═══════════════════════════════",
            "Task ID:         \(taskID.uuidString)",
            "Filename:        \(filename)",
            "Status:          \(status.rawValue)",
            "HTTP Status:     \(httpStatus.map { "\($0)" } ?? "—")",
            "Error Code:      \(errorCode.map { "\($0)" } ?? "—")",
            "Network Error:   \(networkError ?? "—")",
            "Failure Reason:  \(failureReason ?? "—")",
            "Retry Count:     \(retryCount) / \(maxRetries)",
            "Resume Support:  \(canResume ? "Yes (Accept-Ranges: bytes)" : "No")",
            "Range Support:   \(rangeSupported ? "Yes" : "No")",
            "Last Good Byte:  \(ByteCountFormatter.string(fromByteCount: lastSuccessfulByte, countStyle: .file))",
            "Suggested Fix:   \(suggestedFix)",
            "Generated At:    \(ISO8601DateFormatter().string(from: generatedAt))",
        ]

        if !retryHistory.isEmpty {
            lines.append("")
            lines.append("Retry History:")
            for (i, record) in retryHistory.enumerated() {
                let dateStr = ISO8601DateFormatter().string(from: record.date)
                let errStr  = record.errorMessage ?? "—"
                let httpStr = record.httpStatus.map { " [HTTP \($0)]" } ?? ""
                lines.append("  \(i + 1). \(dateStr)\(httpStr): \(errStr)")
            }
        }

        lines.append("═══════════════════════════════")
        return lines.joined(separator: "\n")
    }
}

// MARK: - DownloadDiagnosticsService

/// Actor that produces `DiagnosticsReport` from a task snapshot.
/// All heavy work runs off the MainActor.
public actor DownloadDiagnosticsService {

    public static let shared = DownloadDiagnosticsService()

    public func diagnose(task: DownloadTaskModel) async -> DiagnosticsReport {
        let errorCode    = extractErrorCode(from: task.errorMessage)
        let networkError = extractNetworkError(from: task.errorMessage)
        let canResume    = task.acceptsRanges && task.resumeData != nil
        let suggestion   = buildSuggestion(task: task, httpStatus: task.lastHTTPStatusCode, canResume: canResume)

        return DiagnosticsReport(
            taskID:             task.id,
            filename:           task.filename,
            status:             task.status,
            errorCode:          errorCode,
            httpStatus:         task.lastHTTPStatusCode,
            networkError:       networkError,
            canResume:          canResume,
            retryCount:         task.retryCount,
            maxRetries:         task.maxRetries,
            failureReason:      task.errorMessage,
            lastSuccessfulByte: task.downloadedBytes,
            rangeSupported:     task.acceptsRanges,
            suggestedFix:       suggestion,
            retryHistory:       task.retryHistory,
            generatedAt:        Date()
        )
    }

    // MARK: Private helpers

    private func extractErrorCode(from message: String?) -> Int? {
        guard let msg = message else { return nil }
        // Pattern: "... code -1001 ..."
        let pattern = #"code\s*(-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)),
              let range = Range(match.range(at: 1), in: msg) else { return nil }
        return Int(msg[range])
    }

    private func extractNetworkError(from message: String?) -> String? {
        guard let msg = message else { return nil }
        // Already human-readable in most cases
        if msg.contains("HTTP error") { return nil }  // handled by httpStatus field
        return msg
    }

    private func buildSuggestion(task: DownloadTaskModel, httpStatus: Int?, canResume: Bool) -> String {
        if let http = httpStatus {
            switch http {
            case 401: return "The server requires authentication. Use 'Update Link' to provide credentials in the URL or contact the server administrator."
            case 403: return "Access was denied. The link may have expired. Use 'Update Link' or 'Refresh Link' to provide a new URL."
            case 404: return "File not found on the server. Verify the URL is correct or find a mirror."
            case 410: return "The resource has been permanently removed. Try a mirror or find an alternative source."
            case 416: return "Resume range rejected by server. Tap Retry to restart from the beginning."
            case 429: return "Rate limited by the server. Wait a few minutes before retrying."
            case 500...599: return "Server error (HTTP \(http)). The server is having issues. Try again later."
            default: break
            }
        }

        if task.retryCount >= task.maxRetries {
            return "Maximum retries reached. Check your internet connection and tap Retry, or use 'Update Link' to switch to a working URL."
        }

        if !canResume && task.downloadedBytes > 0 {
            return "Server does not support resume. The download will restart from the beginning on retry."
        }

        if task.mirrors.count > 0 {
            return "Try switching to a mirror URL using the 'Mirrors' option."
        }

        return "Check your internet connection and tap Retry. If the problem persists, use 'Update Link'."
    }
}
