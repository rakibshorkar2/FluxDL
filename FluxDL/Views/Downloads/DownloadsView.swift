import SwiftUI

// MARK: - DownloadsView

public struct DownloadsView: View {
    @StateObject private var viewModel = DownloadsViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 14) {
                    StorageHeaderCard(
                        freeDiskSpace:    viewModel.freeDiskSpaceFormatted,
                        appUsage:         viewModel.appUsageFormatted,
                        usedPercentage:   viewModel.storageUsedPercentage,
                        activeQueueMode:  viewModel.queueModeFormatted,
                        maxConcurrent:    viewModel.maxConcurrentDownloads
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // ── Filter + Sort bar ────────────────────────────────
                    filterSortBar

                    // ── Batch toolbar (visible in selection mode) ────────
                    if viewModel.isSelectionMode {
                        batchToolbar
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // ── Task list ────────────────────────────────────────
                    taskList
                }
            }
            .navigationTitle("Downloads")
            .toolbar { navigationToolbar }
            .animation(.easeInOut(duration: 0.25), value: viewModel.isSelectionMode)
            // ── Sheets ──────────────────────────────────────────────────
            .sheet(isPresented: $viewModel.isAddSheetPresented) {
                AddDownloadSheet { url, filename in viewModel.startNewDownload(url: url, filename: filename) }
            }
            .sheet(isPresented: $viewModel.isQueueSettingsPresented) {
                QueueSettingsSheet()
            }
            .sheet(item: $viewModel.taskForInfoSheet) { task in
                DownloadInfoSheet(task: task)
            }
            .sheet(item: $viewModel.taskForDiagnosticsSheet) { task in
                DownloadDiagnosticsSheet(task: task)
            }
            .sheet(item: $viewModel.taskForUpdateURLSheet) { task in
                UpdateURLSheet(task: task) { newURL in
                    viewModel.updateDownloadURL(newURL, for: task.id)
                }
            }
            .sheet(item: $viewModel.taskForMirrorSheet) { task in
                MirrorPickerSheet(task: task)
            }
            .sheet(isPresented: $viewModel.isDuplicateAlertPresented) {
                if let url = viewModel.pendingDuplicateURL {
                    DuplicateResolutionSheet(
                        newURL: url,
                        existingTask: viewModel.duplicateExistingTask
                    ) { option in
                        viewModel.resolveDuplicate(option)
                    }
                }
            }
            // Delete confirmation (single item)
            .confirmationDialog(
                "Delete Download",
                isPresented: $viewModel.isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete File & Record", role: .destructive) {
                    if let id = viewModel.pendingDeleteID {
                        viewModel.deleteTask(id: id, deleteFile: true)
                    }
                    viewModel.pendingDeleteID = nil
                }
                Button("Remove from List Only", role: .destructive) {
                    if let id = viewModel.pendingDeleteID {
                        viewModel.deleteTask(id: id, deleteFile: false)
                    }
                    viewModel.pendingDeleteID = nil
                }
                Button("Cancel", role: .cancel) {
                    viewModel.pendingDeleteID = nil
                }
            } message: {
                Text("This action cannot be undone.")
            }
            // Batch delete confirmation
            .confirmationDialog(
                "Delete \(viewModel.selectedCount) Downloads",
                isPresented: $viewModel.isBatchDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete Files & Records", role: .destructive) {
                    viewModel.batchDelete(deleteFiles: true)
                }
                Button("Remove from List Only", role: .destructive) {
                    viewModel.batchDelete(deleteFiles: false)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \(viewModel.selectedCount) selected downloads.")
            }
            .onAppear { viewModel.refreshStorageInfo() }
        }
    }

    // MARK: Filter + Sort Bar

    private var filterSortBar: some View {
        HStack(spacing: 8) {
            // Filter menu
            Menu {
                ForEach(DownloadStatusFilter.allCases) { filter in
                    Button {
                        viewModel.filterState.filter = filter
                    } label: {
                        HStack {
                            Label(filter.rawValue, systemImage: filter.systemImage)
                            Spacer()
                            if let count = viewModel.countByFilter[filter] {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                            }
                            if viewModel.filterState.filter == filter {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.filterState.filter.systemImage)
                    Text(viewModel.filterState.filter.rawValue)
                    if let count = viewModel.countByFilter[viewModel.filterState.filter] {
                        Text("(\(count))")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(Capsule())
            }

            // Sort menu
            Menu {
                // Sort keys
                Section("Sort By") {
                    ForEach(DownloadSortKey.allCases) { key in
                        Button {
                            if viewModel.filterState.sortKey == key {
                                // Flip direction
                                viewModel.filterState.direction =
                                    viewModel.filterState.direction == .ascending ? .descending : .ascending
                            } else {
                                viewModel.filterState.sortKey   = key
                                viewModel.filterState.direction = .descending
                            }
                        } label: {
                            HStack {
                                Label(key.rawValue, systemImage: key.systemImage)
                                if viewModel.filterState.sortKey == key {
                                    Image(systemName: viewModel.filterState.direction == .ascending
                                          ? "arrow.up" : "arrow.down")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.filterState.sortKey.systemImage)
                    Text(viewModel.filterState.sortKey.rawValue)
                    Image(systemName: viewModel.filterState.direction == .ascending ? "arrow.up" : "arrow.down")
                        .font(.caption2)
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: Batch Toolbar

    private var batchToolbar: some View {
        HStack(spacing: 8) {
            // Select All / Deselect All
            Button {
                if viewModel.selectedCount == viewModel.displayedTasks.count {
                    viewModel.deselectAll()
                } else {
                    viewModel.selectAll()
                }
            } label: {
                Text(viewModel.selectedCount == viewModel.displayedTasks.count ? "Deselect All" : "Select All")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            // Batch actions
            if viewModel.canBatchPause {
                Button(action: viewModel.batchPause) {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
            }

            if viewModel.canBatchResume {
                Button(action: viewModel.batchResume) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
            }

            if viewModel.canBatchRetry {
                Button(action: viewModel.batchRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if viewModel.selectedCount > 0 {
                Button {
                    viewModel.isBatchDeleteConfirmationPresented = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Task List

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if viewModel.displayedTasks.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.displayedTasks) { task in
                        EquatableDownloadItemCard(
                            task:             task,
                            isSelectionMode:  viewModel.isSelectionMode,
                            isSelected:       viewModel.selectedIDs.contains(task.id),
                            onPause:          { viewModel.pauseTask(id: task.id) },
                            onResume:         { viewModel.resumeTask(id: task.id) },
                            onCancel:         { viewModel.cancelTask(id: task.id) },
                            onRetry:          { viewModel.retryTask(id: task.id) },
                            onDelete:         { viewModel.confirmDeleteTask(id: task.id) },
                            onShare:          { viewModel.shareTask(task: task) },
                            onChangePriority: { p in viewModel.changeTaskPriority(id: task.id, newPriority: p) },
                            onShowInfo:       { viewModel.taskForInfoSheet = task },
                            onUpdateURL:      { viewModel.taskForUpdateURLSheet = task },
                            onShowMirrors:    { viewModel.taskForMirrorSheet = task },
                            onShowDiagnostics:{ viewModel.taskForDiagnosticsSheet = task },
                            onToggleSelect:   { viewModel.toggleSelection(id: task.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 14) {
                Image(systemName: viewModel.filterState.filter == .all
                      ? "tray" : viewModel.filterState.filter.systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text(emptyTitle)
                    .font(.headline)

                Text(emptySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if viewModel.filterState.filter != .all {
                    Button {
                        viewModel.filterState.filter = .all
                    } label: {
                        Label("Show All Downloads", systemImage: "tray.full")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 20)
    }

    private var emptyTitle: String {
        switch viewModel.filterState.filter {
        case .all:       return "No Downloads"
        case .active:    return "No Active Downloads"
        case .paused:    return "No Paused Downloads"
        case .failed:    return "No Failed Downloads"
        case .completed: return "No Completed Downloads"
        case .waiting:   return "Queue is Empty"
        case .cancelled: return "No Cancelled Downloads"
        }
    }

    private var emptySubtitle: String {
        switch viewModel.filterState.filter {
        case .all:       return "Tap '+' to start downloading a direct file URL."
        case .active:    return "No downloads are currently in progress."
        case .paused:    return "No downloads have been paused."
        case .failed:    return "No downloads have failed."
        case .completed: return "Downloaded files will appear here."
        case .waiting:   return "No downloads are queued and waiting."
        case .cancelled: return "No downloads have been cancelled."
        }
    }

    // MARK: Navigation Toolbar

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        // Leading: Queue settings OR selection count
        ToolbarItem(placement: .topBarLeading) {
            if viewModel.isSelectionMode {
                Text(viewModel.selectedCount == 0
                     ? "Select Items"
                     : "\(viewModel.selectedCount) Selected")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
                    .animation(.none, value: viewModel.selectedCount)
            } else {
                Button(action: { viewModel.isQueueSettingsPresented = true }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body)
                        .foregroundStyle(Color.primary)
                }
            }
        }

        // Trailing: Select mode toggle + Add button
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                Button(action: viewModel.toggleSelectionMode) {
                    Text(viewModel.isSelectionMode ? "Done" : "Select")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.accentColor)
                }

                if !viewModel.isSelectionMode {
                    Button(action: { viewModel.isAddSheetPresented = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
}

// MARK: - DownloadTaskModel: Identifiable for .sheet(item:)

// DownloadTaskModel already conforms to Identifiable via `id: UUID`.
