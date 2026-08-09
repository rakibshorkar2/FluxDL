import SwiftUI

// MARK: - TorrentView

public struct TorrentView: View {
    @StateObject private var viewModel = TorrentViewModel()

    @State private var pendingRemoveID: String?
    @State private var isRemoveConfirmationPresented = false
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

                        if viewModel.torrents.isEmpty {
                            emptyState
                        } else if viewModel.visibleTorrents.isEmpty {
                            noResultsState
                        } else {
                            ForEach(viewModel.visibleTorrents) { torrent in
                                TorrentItemCard(
                                    torrent: torrent,
                                    onPause: { viewModel.pause(torrent.id) },
                                    onResume: { viewModel.resume(torrent.id) },
                                    onRemove: { deleteFiles in
                                        pendingRemoveID = torrent.id
                                        isRemoveConfirmationPresented = true
                                    },
                                    onShowDetail: { viewModel.taskForDetail = torrent }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .searchable(text: $viewModel.searchText, prompt: "Search torrents")
            }
            .navigationTitle("Torrent")
            .toolbar { navigationToolbar }
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
                "Remove Torrent",
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
                Text("Downloaded files will be deleted if you choose the delete option.")
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
                Image(systemName: "network")
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

    // MARK: - Navigation Toolbar

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !viewModel.torrents.isEmpty {
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

                    Divider()

                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Torrent Settings", systemImage: "gearshape.fill")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body)
                        .foregroundStyle(Color.primary)
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
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
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
