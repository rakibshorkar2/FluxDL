import Foundation

// MARK: - DownloadStatusFilter

/// Comprehensive filter for the Downloads list — superset of the old two-tab approach.
public enum DownloadStatusFilter: String, Codable, CaseIterable, Identifiable {
    case all        = "All"
    case active     = "Active"
    case paused     = "Paused"
    case failed     = "Failed"
    case completed  = "Completed"
    case waiting    = "Waiting"
    case cancelled  = "Cancelled"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .all:       return "tray.full"
        case .active:    return "arrow.down.circle"
        case .paused:    return "pause.circle"
        case .failed:    return "exclamationmark.circle"
        case .completed: return "checkmark.circle"
        case .waiting:   return "clock.arrow.circlepath"
        case .cancelled: return "xmark.circle"
        }
    }

    /// Returns true if the given status belongs to this filter category.
    func matches(_ status: DownloadStatus) -> Bool {
        switch self {
        case .all:       return true
        case .active:    return status == .downloading
        case .paused:    return status == .paused
        case .failed:    return status == .failed
        case .completed: return status == .completed
        case .waiting:   return status == .pending
        case .cancelled: return status == .cancelled
        }
    }
}

// MARK: - DownloadSortKey

public enum DownloadSortKey: String, Codable, CaseIterable, Identifiable {
    case name        = "Name"
    case dateAdded   = "Date Added"
    case lastUpdated = "Last Updated"
    case size        = "Size"
    case progress    = "Progress"
    case status      = "Status"
    case fileType    = "File Type"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .name:        return "textformat.abc"
        case .dateAdded:   return "calendar.badge.plus"
        case .lastUpdated: return "clock"
        case .size:        return "internaldrive"
        case .progress:    return "chart.bar"
        case .status:      return "circle.dashed"
        case .fileType:    return "doc"
        }
    }
}

// MARK: - SortDirection

public enum SortDirection: String, Codable, CaseIterable {
    case ascending  = "Ascending"
    case descending = "Descending"
}

// MARK: - DownloadFilterState

/// Persisted filter + sort preference.
public struct DownloadFilterState: Codable, Equatable {
    public var filter:    DownloadStatusFilter
    public var sortKey:   DownloadSortKey
    public var direction: SortDirection

    public init(
        filter:    DownloadStatusFilter = .all,
        sortKey:   DownloadSortKey      = .dateAdded,
        direction: SortDirection        = .descending
    ) {
        self.filter    = filter
        self.sortKey   = sortKey
        self.direction = direction
    }

    // MARK: Persistence

    private static let defaultsKey = "fluxdl_download_filter_state"

    public static func load() -> DownloadFilterState {
        guard let data  = UserDefaults.standard.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(DownloadFilterState.self, from: data) else {
            return DownloadFilterState()
        }
        return state
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Filter + Sort Function

/// Pure function — no actors, no side effects. Safe to call on any thread.
public func applyFilterAndSort(
    _ tasks: [DownloadTaskModel],
    state: DownloadFilterState
) -> [DownloadTaskModel] {
    // 1. Filter
    let filtered = tasks.filter { state.filter.matches($0.status) }

    // 2. Sort
    let sorted = filtered.sorted { a, b -> Bool in
        let ascending: Bool
        switch state.sortKey {
        case .name:
            ascending = a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        case .dateAdded:
            ascending = a.createdAt < b.createdAt
        case .lastUpdated:
            let aDate = a.completedAt ?? a.startedAt ?? a.createdAt
            let bDate = b.completedAt ?? b.startedAt ?? b.createdAt
            ascending = aDate < bDate
        case .size:
            let aSize = a.totalBytes > 0 ? a.totalBytes : a.downloadedBytes
            let bSize = b.totalBytes > 0 ? b.totalBytes : b.downloadedBytes
            ascending = aSize < bSize
        case .progress:
            ascending = a.progress < b.progress
        case .status:
            ascending = a.status.rawValue < b.status.rawValue
        case .fileType:
            let aExt = (a.filename as NSString).pathExtension.lowercased()
            let bExt = (b.filename as NSString).pathExtension.lowercased()
            ascending = aExt < bExt
        }
        return state.direction == .ascending ? ascending : !ascending
    }

    return sorted
}
