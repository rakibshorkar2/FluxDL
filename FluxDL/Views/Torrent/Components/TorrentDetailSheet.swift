import SwiftUI
import LibTorrent

public struct TorrentDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject public var viewModel: TorrentViewModel
    public let torrentID: String

    @State private var newTrackerURL: String = ""
    @State private var isRemoveConfirmationPresented = false

    public init(viewModel: TorrentViewModel, torrentID: String) {
        self.viewModel = viewModel
        self.torrentID = torrentID
    }

    private var torrent: TorrentTaskModel? {
        viewModel.liveModel(for: torrentID)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let torrent = torrent {
                    List {
                        headerSection(torrent)
                        statsSection(torrent)
                        downloadOptionsSection(torrent)
                        speedLimitsSection(torrent)

                        if !torrent.files.isEmpty {
                            filesSection(torrent)
                        }

                        trackersSection(torrent)

                        metadataSection(torrent)

                        actionsSection(torrent)
                    }
                } else {
                    ContentUnavailableView(
                        "Torrent Removed",
                        systemImage: "trash",
                        description: Text("This torrent is no longer in the session.")
                    )
                }
            }
            .navigationTitle(torrent?.name ?? "Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Remove Torrent",
                isPresented: $isRemoveConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Remove (Keep Files)", role: .destructive) {
                    viewModel.remove(torrentID, deleteFiles: false)
                    dismiss()
                }
                Button("Remove & Delete Files", role: .destructive) {
                    viewModel.remove(torrentID, deleteFiles: true)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Downloaded files will be deleted if you choose the delete option.")
            }
        }
    }

    // MARK: - Sections

    private func headerSection(_ torrent: TorrentTaskModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(torrent.name)
                    .font(.headline)

                StatusBadge(
                    title: torrent.state.displayTitle,
                    icon: torrent.state.displayIcon,
                    color: torrent.state.displayColor
                )

                if torrent.total > 0 {
                    ProgressView(value: torrent.progress)
                        .tint(torrent.state == .storageError ? Color.red : Color.accentColor)

                    Text("\(Int(torrent.progress * 100))% completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statsSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Stats") {
            LabeledContent("Download", value: TorrentByteFormatter.rate(torrent.downloadRate))
            LabeledContent("Upload", value: TorrentByteFormatter.rate(torrent.uploadRate))
            LabeledContent("Size", value: TorrentByteFormatter.string(torrent.total))
            LabeledContent("Downloaded", value: TorrentByteFormatter.string(torrent.totalDone))
            LabeledContent("Seeds", value: "\(torrent.seeds) (\(torrent.totalSeeds) total)")
            LabeledContent("Peers", value: "\(torrent.peers) (\(torrent.totalPeers) total)")
        }
    }

    private func downloadOptionsSection(_ torrent: TorrentTaskModel) -> some View {
        Section(header: Text("Download Options"), footer: Text("Sequential download reads pieces in order, best for video playback. First/last pieces let playback start sooner.")) {
            Toggle("Stop seeding when download completes", isOn: Binding(
                get: { torrent.stopSeeding },
                set: { enabled in viewModel.setStopSeeding(torrentID, enabled: enabled) }
            ))

            Toggle("Sequential download", isOn: Binding(
                get: { torrent.isSequential },
                set: { enabled in viewModel.setSequentialDownload(torrentID, enabled: enabled) }
            ))

            Toggle("Download first & last pieces first", isOn: Binding(
                get: { torrent.isFirstLastPiecePriority },
                set: { enabled in viewModel.setFirstLastPriorityDownload(torrentID, enabled: enabled) }
            ))
        }
    }

    private func speedLimitsSection(_ torrent: TorrentTaskModel) -> some View {
        Section(header: Text("Speed Limits"), footer: Text("Per-torrent limits never exceed the global limits from Torrent Settings.")) {
            Picker("Download Limit", selection: Binding(
                get: { TorrentSpeedPreset(rawValue: Int(torrent.downloadLimit)) ?? .unlimited },
                set: { preset in viewModel.setDownloadLimit(torrentID, bytesPerSecond: Int64(preset.rawValue)) }
            )) {
                ForEach(TorrentSpeedPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }

            Picker("Upload Limit", selection: Binding(
                get: { TorrentSpeedPreset(rawValue: Int(torrent.uploadLimit)) ?? .unlimited },
                set: { preset in viewModel.setUploadLimit(torrentID, bytesPerSecond: Int64(preset.rawValue)) }
            )) {
                ForEach(TorrentSpeedPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
        }
    }

    private func filesSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Files") {
            Menu {
                Button("Normal Priority") { viewModel.setAllFilesPriority(torrentID, priority: .defaultPriority) }
                Button("Don't Download") { viewModel.setAllFilesPriority(torrentID, priority: .dontDownload) }
                Button("High Priority") { viewModel.setAllFilesPriority(torrentID, priority: .topPriority) }
            } label: {
                Label("Apply to All Files", systemImage: "slider.horizontal.3")
            }

            ForEach(torrent.files) { file in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(2)

                        Spacer()

                        Menu {
                            Button("Normal") { viewModel.setFilePriority(torrentID, index: file.index, priority: .defaultPriority) }
                            Button("Don't Download") { viewModel.setFilePriority(torrentID, index: file.index, priority: .dontDownload) }
                            Button("High") { viewModel.setFilePriority(torrentID, index: file.index, priority: .topPriority) }
                        } label: {
                            Text(priorityTitle(file.priority))
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(file.priority == .dontDownload
                                            ? Color.red.opacity(0.15)
                                            : file.priority == .topPriority ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    HStack {
                        if file.size > 0 {
                            ProgressView(value: Double(file.downloaded), total: Double(file.size))
                                .tint(Color.accentColor)
                        }

                        Text("\(TorrentByteFormatter.string(file.downloaded)) / \(TorrentByteFormatter.string(file.size))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func trackersSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Trackers") {
            HStack {
                TextField("Add tracker URL (udp:// or https://)", text: $newTrackerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    viewModel.addTracker(torrentID, url: newTrackerURL)
                    newTrackerURL = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                viewModel.forceReannounce(torrentID)
            } label: {
                Label("Reannounce to Trackers", systemImage: "arrow.clockwise")
            }

            ForEach(torrent.trackers) { tracker in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tracker.url)
                        .font(.caption)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Text(trackerStateTitle(tracker))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if tracker.seeds + tracker.peers + tracker.leeches > 0 {
                            Text("S:\(tracker.seeds) P:\(tracker.peers) L:\(tracker.leeches)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let message = tracker.message, !message.isEmpty {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.removeTracker(torrentID, url: tracker.url)
                    } label: {
                        Label("Remove Tracker", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.removeTracker(torrentID, url: tracker.url)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func metadataSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Info") {
            if let magnet = torrent.magnetLink {
                Button {
                    viewModel.copyMagnetLink(torrentID)
                } label: {
                    Label("Copy Magnet Link", systemImage: "doc.on.doc")
                }
            }

            if let comment = torrent.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let creator = torrent.creator, !creator.isEmpty {
                LabeledContent("Created By", value: creator)
            }

            if let date = torrent.creationDate {
                LabeledContent("Created", value: date.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func actionsSection(_ torrent: TorrentTaskModel) -> some View {
        Section {
            if torrent.state == .paused || torrent.state == .storageError {
                Button {
                    viewModel.resume(torrentID)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
            } else {
                Button {
                    viewModel.pause(torrentID)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            }

            Button {
                viewModel.rehash(torrentID)
            } label: {
                Label("Recheck Files", systemImage: "magnifyingglass")
            }

            Button(role: .destructive) {
                isRemoveConfirmationPresented = true
            } label: {
                Label("Remove Torrent", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private func priorityTitle(_ priority: FileEntry.Priority) -> String {
        switch priority {
        case .dontDownload: return "Skip"
        case .defaultPriority: return "Normal"
        case .lowPriority: return "Low"
        case .topPriority: return "High"
        }
    }

    private func trackerStateTitle(_ tracker: TorrentTrackerItem) -> String {
        switch tracker.state {
        case .notContacted: return "Not contacted"
        case .working: return "Working"
        case .updating: return "Updating"
        case .notWorking: return "Not working"
        case .trackerError: return "Tracker error"
        case .unreachable: return "Unreachable"
        }
    }
}
