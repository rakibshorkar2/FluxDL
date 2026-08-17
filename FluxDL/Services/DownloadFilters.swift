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

// MARK: - DownloadDisplayItem

/// One row of the Downloads tab: either a standalone task or an expandable
/// folder download group.
public enum DownloadDisplayItem: Identifiable, Equatable {
    case task(DownloadTaskModel)
    case folder(FolderGroupSnapshot)

    public var id: UUID {
        switch self {
        case .task(let task): return task.id
        case .folder(let snapshot): return snapshot.id
        }
    }

    var sortName: String {
        switch self {
        case .task(let task): return task.filename
        case .folder(let snapshot): return snapshot.group.name
        }
    }

    var sortDate: Date {
        switch self {
        case .task(let task): return task.createdAt
        case .folder(let snapshot): return snapshot.group.createdAt
        }
    }

    var sortLastUpdated: Date {
        switch self {
        case .task(let task): return task.completedAt ?? task.startedAt ?? task.createdAt
        case .folder(let snapshot):
            let latest = snapshot.children.compactMap { $0.task.completedAt ?? $0.task.startedAt }.max()
            return latest ?? snapshot.group.createdAt
        }
    }

    var sortSize: Int64 {
        switch self {
        case .task(let task): return task.totalBytes > 0 ? task.totalBytes : task.downloadedBytes
        case .folder(let snapshot): return snapshot.totalBytes > 0 ? snapshot.totalBytes : snapshot.downloadedBytes
        }
    }

    var sortProgress: Double {
        switch self {
        case .task(let task): return task.progress
        case .folder(let snapshot): return snapshot.progress
        }
    }

    var sortStatus: String {
        switch self {
        case .task(let task): return task.status.rawValue
        case .folder(let snapshot): return snapshot.state.rawValue
        }
    }

    var sortFileType: String {
        switch self {
        case .task(let task): return (task.filename as NSString).pathExtension.lowercased()
        case .folder: return "folder"
        }
    }
}

// MARK: - Filter + Sort Function (display items)

/// Pure function — no actors, no side effects. Safe to call on any thread.
/// Applies the Downloads filter/sort to the unified list of standalone tasks
/// and folder download groups.
public func applyFilterAndSortItems(
    _ items: [DownloadDisplayItem],
    state: DownloadFilterState
) -> [DownloadDisplayItem] {
    let filtered = items.filter { item in
        switch item {
        case .task(let task): return state.filter.matches(task.status)
        case .folder(let snapshot): return snapshot.matchesFilter(state.filter)
        }
    }

    let sorted = filtered.sorted { a, b -> Bool in
        let ascending: Bool
        switch state.sortKey {
        case .name:
            ascending = a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
        case .dateAdded:
            ascending = a.sortDate < b.sortDate
        case .lastUpdated:
            ascending = a.sortLastUpdated < b.sortLastUpdated
        case .size:
            ascending = a.sortSize < b.sortSize
        case .progress:
            ascending = a.sortProgress < b.sortProgress
        case .status:
            ascending = a.sortStatus < b.sortStatus
        case .fileType:
            ascending = a.sortFileType < b.sortFileType
        }
        return state.direction == .ascending ? ascending : !ascending
    }

    return sorted
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
