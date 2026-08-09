import SwiftUI

// MARK: - TorrentView

public struct TorrentView: View {
    @StateObject private var viewModel = TorrentViewModel()

    @State private var pendingRemoveID: String?
    @State private var isRemoveConfirmationPresented = false
    @State private var isPauseAllPresented = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 14) {
                        sessionStatsCard

                        if viewModel.torrents.isEmpty {
                            emptyState
                        } else {
                            ForEach(viewModel.torrents) { torrent in
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
            }
            .navigationTitle("Torrent")
            .toolbar { navigationToolbar }
            // ── Sheets ────────────────────────────────────────────────────
            .sheet(isPresented: $viewModel.isAddSheetPresented) {
                AddTorrentSheet(
                    onAddMagnet: { string in viewModel.addMagnet(string) },
                    onAddTorrentFile: { url in viewModel.addTorrentFile(at: url) },
                    onAddRemoteTorrent: { url in viewModel.addRemoteTorrent(url) }
                )
            }
            .sheet(item: $viewModel.taskForDetail) { task in
                TorrentDetailSheet(viewModel: viewModel, torrentID: task.id)
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
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body)
                        .foregroundStyle(Color.primary)
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
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
