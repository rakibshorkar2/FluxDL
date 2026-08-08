//
//  DownloadItem.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Foundation

struct DownloadItem: Codable, Hashable, Identifiable {
    enum Status: String, Codable {
        case queued
        case downloading
        case paused
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    var url: String
    var filename: String
    var status: Status
    var bytesReceived: Int64
    var totalBytes: Int64
    var speed: Int64
    var errorMessage: String?
    var hasResumeData: Bool
    var downloadedFilename: String?
    var createdAt: Date

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }

    static func make(url: URL, filename: String) -> DownloadItem {
        DownloadItem(
            id: UUID(),
            url: url.absoluteString,
            filename: filename,
            status: .queued,
            bytesReceived: 0,
            totalBytes: 0,
            speed: 0,
            errorMessage: nil,
            hasResumeData: false,
            downloadedFilename: nil,
            createdAt: Date()
        )
    }
}