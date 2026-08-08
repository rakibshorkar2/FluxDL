//
//  DownloadsPreferences.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import Combine
import Foundation

class DownloadsPreferences {
    static let shared = DownloadsPreferences()
    private init() {}

    @UserDefaultItem("downloadsMaxActive", 3) var maxActiveDownloads: Int
    @UserDefaultItem("downloadsAllowsCellular", false) var allowsCellular: Bool
    @UserDefaultItem("downloadsAutoRetry", true) var autoRetryFailed: Bool
}
