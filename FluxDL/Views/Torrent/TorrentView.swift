import SwiftUI

// MARK: - TorrentView

public struct TorrentView: View {
    @StateObject private var viewModel = TorrentViewModel()

    @State private var pendingRemoveID: String?
    @State private var isRemoveConfirmationPresented = false
    @State private var isBatchRemovePresented = false
    @State private var isPauseAllPresented = false
    @State private var isSettingsPresented = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 14) {
                        sessionStatsCard
                        filterChips

                        if viewModel.torrents.isEmpty && viewModel.deletingTorrents.isEmpty {
                            emptyState
                        } else if viewModel.visibleTorrents.isEmpty && viewModel.deletingTorrents.isEmpty {
                            noResultsState
                        } else {
                            ForEach(viewModel.displayedTorrents) { torrent in
                                TorrentItemCard(
                                    torrent: torrent,
                                    isDeleting: viewModel.isDeleting(torrent.id),
                                    isSelectionMode: viewModel.isEditing,
                                    isSelected: viewModel.isSelected(torrent.id),
                                    onPause: { viewModel.pause(torrent.id) },
                                    onResume: { viewModel.resume(torrent.id) },
                                    onRemove: { deleteFiles in
                                        pendingRemoveID = torrent.id
                                        isRemoveConfirmationPresented = true
                                    },
                                    onShowDetail: { viewModel.taskForDetail = torrent },
                                    onToggleSelection: { viewModel.toggleSelection(torrent.id) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .searchable(text: $viewModel.searchText, prompt: "Search torrents")
                // ── Undo removal toast ─────────────────────────────────────
                .overlay(alignment: .bottom) {
                    if let toast = viewModel.undoToast {
                        undoToastView(toast)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.undoToast)
            }
            .navigationTitle("Torrent")
            .toolbar { navigationToolbar }
            // ── Edit mode action bar ──────────────────────────────────────
            .safeAreaInset(edge: .bottom) {
                if viewModel.isEditing {
                    editActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.isEditing)
            // ── Sheets ────────────────────────────────────────────────────
            .sheet(isPresented: $viewModel.isAddSheetPresented) {
                AddTorrentSheet(
                    onAddMagnet: { string, options in viewModel.addMagnet(string, options: options) },
                    onAddTorrentFile: { url, options in viewModel.addTorrentFile(at: url, options: options) },
                    onAddRemoteTorrent: { url, options in viewModel.addRemoteTorrent(url, options: options) }
                )
            }
            .sheet(item: $viewModel.taskForDetail) { task in
                TorrentDetailSheet(viewModel: viewModel, torrentID: task.id)
            }
            .sheet(isPresented: $isSettingsPresented) {
                TorrentSettingsSheet(viewModel: viewModel)
            }
            // ── Confirmations ─────────────────────────────────────────────
            .confirmationDialog(
                removeDialogTitle,
                isPresented: $isRemoveConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Remove (Keep Files)", role: .destructive) {
                    if let id = pendingRemoveID { viewModel.remove(id, deleteFiles: false) }
                    pendingRemoveID = nil
                }
                Button("Remove & Delete Files", role: .destructive) {
                    if let id = pendingRemoveID { viewModel.remove(id, deleteFiles: true) }
                    pendingRemoveID = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoveID = nil }
            } message: {
                Text("Remove '\(pendingTorrentName)' from the torrent list? Downloaded files are kept unless you choose to delete them.")
            }
            .confirmationDialog(
                batchRemoveDialogTitle,
                isPresented: $isBatchRemovePresented,
                titleVisibility: .visible
            ) {
                Button("Remove \(batchCountText) (Keep Files)", role: .destructive) {
                    viewModel.removeSelected(deleteFiles: false)
                }
                Button("Remove \(batchCountText) & Delete Files", role: .destructive) {
                    viewModel.removeSelected(deleteFiles: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove the selected torrents? Download files are kept unless you choose to delete them.")
            }
            .confirmationDialog(
                "Pause All Torrents",
                isPresented: $isPauseAllPresented,
                titleVisibility: .visible
            ) {
                Button("Pause All", role: .destructive) { viewModel.pauseAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pause all \(viewModel.torrents.count) torrents?")
            }
            .alert("Error", isPresented: $viewModel.isAlertPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.alertMessage ?? "Unknown error.")
            }
            .onAppear { viewModel.startSessionIfNeeded() }
        }
    }

    // MARK: - Edit Action Bar

    private var editActionBar: some View {
        let isAllSelected = !viewModel.visibleTorrents.isEmpty
            && viewModel.visibleTorrents.allSatisfy { viewModel.isSelected($0.id) }

        return HStack(spacing: 12) {
            Button {
                if isAllSelected {
                    viewModel.deselectAll()
                } else {
                    viewModel.selectAllVisible()
                }
            } label: {
                Text(isAllSelected ? "Deselect All" : "Select All")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .disabled(viewModel.visibleTorrents.isEmpty)

            Spacer()

            Button {
                viewModel.pauseSelected()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(!viewModel.canPauseSelection)

            Button {
                viewModel.resumeSelected()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(!viewModel.canResumeSelection)

            Button(role: .destructive) {
                isBatchRemovePresented = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(viewModel.selectedIDs.isEmpty)

            Menu {
                Button {
                    isPauseAllPresented = true
                } label: {
                    Label("Pause All", systemImage: "pause.fill")
                }
                Button {
                    viewModel.resumeAll()
                } label: {
                    Label("Resume All", systemImage: "play.fill")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Session Stats Card

    private var sessionStatsCard: some View {
        GlassCard(padding: 14, cornerRadius: AppTheme.cornerRadiusMedium) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Torrent Session")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(viewModel.isSessionActive ? "Active" : "Starting…")
                        .font(.headline)

                    Text("\(viewModel.torrents.count) torrent\(viewModel.torrents.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.totalDownloadRate > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Label(TorrentByteFormatter.rate(viewModel.totalDownloadRate), systemImage: "arrow.down")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.blue)
                        Text("total download")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.totalUploadRate > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Label(TorrentByteFormatter.rate(viewModel.totalUploadRate), systemImage: "arrow.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.green)
                        Text("total upload")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TorrentFilter.allCases) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.filter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                viewModel.filter == filter
                                    ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                            )
                            .foregroundStyle(
                                viewModel.filter == filter
                                    ? Color.white
                                    : Color.primary
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 14) {
                Image(systemName: "magnet")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("No Torrents")
                    .font(.headline)

                Text("Add a magnet link, a .torrent file, or a remote .torrent URL to start downloading.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    viewModel.isAddSheetPresented = true
                } label: {
                    Label("Add Torrent", systemImage: "plus.circle.fill")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 20)
    }

    private var noResultsState: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("No Matching Torrents")
                    .font(.headline)

                Text("Try a different search term or filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 20)
    }

    // MARK: - Undo Removal Toast

    private var pendingTorrentName: String {
        guard let id = pendingRemoveID else { return "this torrent" }
        return viewModel.liveModel(for: id)?.name ?? "this torrent"
    }

    private var removeDialogTitle: String {
        pendingRemoveID == nil ? "Remove Torrent" : "Remove '\(pendingTorrentName)'"
    }

    private var batchCountText: String {
        let count = viewModel.selectedIDs.count
        return count == 1 ? "1 Torrent" : "\(count) Torrents"
    }

    private var batchRemoveDialogTitle: String {
        let count = viewModel.selectedIDs.count
        return count == 1 ? "Delete Torrent?" : "Delete \(count) Torrents?"
    }

    private func undoToastView(_ toast: TorrentUndoToast) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))

                Text(toast.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.undoRemoval()
            } label: {
                Text("Undo")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.accentColor)
                    .foregroundStyle(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!toast.records.contains { $0.magnetLink != nil })

            Button {
                viewModel.dismissUndoToast()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium))
        .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
    }

    // MARK: - Navigation Toolbar

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !viewModel.torrents.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleEditMode()
                    }
                } label: {
                    Text(viewModel.isEditing ? "Done" : "Edit")
                        .fontWeight(.semibold)
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                Menu {
                    Picker("Sort By", selection: $viewModel.sortOrder) {
                        ForEach(TorrentSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }

                    Picker("Order", selection: $viewModel.sortDirection) {
                        ForEach(TorrentSortDirection.allCases) { direction in
                            Text(direction.rawValue).tag(direction)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body)
                        .foregroundStyle(Color.primary)
                }

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.body)
                        .foregroundStyle(Color.primary)
                }

                Button {
                    viewModel.isAddSheetPresented = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}