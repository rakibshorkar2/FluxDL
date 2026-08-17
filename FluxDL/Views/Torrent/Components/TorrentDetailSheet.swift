import SwiftUI
import LibTorrent

// MARK: - TorrentDetailSheet

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

    /// The sheet always resolves its content from the stable `torrentID`, never
    /// from list position, so popups and rows can never target another torrent.
    private var torrent: TorrentTaskModel? {
        viewModel.liveModel(for: torrentID)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let torrent = torrent {
                    List {
                        overviewSection(torrent)
                        transferSection(torrent)
                        peersSection(torrent)
                        seedingSection(torrent)
                        torrentInfoSection(torrent)

                        if !torrent.files.isEmpty {
                            filesSection(torrent)
                        }

                        trackersSection(torrent)
                        downloadOptionsSection(torrent)
                        speedLimitsSection(torrent)
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
                removeDialogTitle,
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
                Text("The torrent will be removed from the session. Downloaded files will be deleted only if you choose the delete option.")
            }
        }
    }

    private var removeDialogTitle: String {
        guard let name = torrent?.name else { return "Remove Torrent" }
        return "Remove '\(name)'"
    }

    // MARK: - Overview

    private func overviewSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Overview") {
            HStack(spacing: 10) {
                StatusBadge(
                    title: torrent.statusTitle,
                    icon: torrent.isStalled ? "exclamationmark.triangle.fill" : torrent.state.displayIcon,
                    color: torrent.isStalled ? .orange : torrent.state.displayColor
                )

                if torrent.isStalled {
                    Text("No progress for a while — check trackers and peers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if torrent.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: torrent.clampedProgress)
                        .tint(torrent.state == .storageError ? Color.red : Color.accentColor)

                    Text("\(torrent.displayPercentage)% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Downloaded", value: "\(TorrentByteFormatter.string(torrent.totalDone)) of \(TorrentByteFormatter.string(torrent.total))")
                LabeledContent("Remaining", value: TorrentByteFormatter.string(torrent.remainingBytes))
                LabeledContent("Total Size", value: TorrentByteFormatter.string(torrent.total))
            }

            if torrent.state == .downloading {
                LabeledContent("ETA", value: etaText(torrent))
            }

            LabeledContent("Added", value: torrent.createdAt.formatted(date: .abbreviated, time: .shortened))

            if let created = torrent.creationDate {
                LabeledContent("Created (metadata)", value: created.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    // MARK: - Transfer

    private func transferSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Transfer") {
            LabeledContent("Download Speed", value: TorrentByteFormatter.rate(torrent.downloadRate))
            LabeledContent("Upload Speed", value: TorrentByteFormatter.rate(torrent.uploadRate))

            if let average = torrent.averageDownloadRate {
                LabeledContent("Average Download", value: TorrentByteFormatter.rate(average))
            }
            if let average = torrent.averageUploadRate {
                LabeledContent("Average Upload", value: TorrentByteFormatter.rate(average))
            }

            LabeledContent("Total Downloaded", value: TorrentByteFormatter.string(torrent.totalDownload))
            LabeledContent("Total Uploaded", value: TorrentByteFormatter.string(torrent.totalUpload))
        }
    }

    // MARK: - Peers

    private func peersSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Peers") {
            LabeledContent("Connected", value: "\(max(0, torrent.peers))")
            LabeledContent("Seeders Connected", value: "\(max(0, torrent.seeds))")
            LabeledContent("Leechers Connected", value: "\(max(0, torrent.leechers))")
            LabeledContent("In Swarm", value: "\(max(0, torrent.totalPeers)) peers, \(max(0, torrent.totalSeeds)) seeds, \(max(0, torrent.totalLeechers)) leechers")
        }
    }

    // MARK: - Seeding

    private func seedingSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Seeding") {
            LabeledContent("Uploaded", value: TorrentByteFormatter.string(torrent.totalUpload))
            if let ratio = torrent.ratio {
                LabeledContent("Ratio", value: String(format: "%.2f", ratio))
            } else {
                LabeledContent("Ratio", value: "—")
            }
        }
    }

    // MARK: - Torrent Info

    private func torrentInfoSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Torrent Info") {
            if let magnet = torrent.magnetLink {
                Button {
                    viewModel.copyMagnetLink(torrentID)
                } label: {
                    Label("Copy Magnet Link", systemImage: "doc.on.doc")
                }
            }

            LabeledContent("Hash") {
                Text(torrent.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if torrent.pieceCount > 0 {
                LabeledContent("Pieces", value: "\(torrent.pieceCount) × \(TorrentByteFormatter.string(Int64(torrent.pieceLength)))")
            }

            if let savePath = torrent.downloadPath {
                LabeledContent("Save Location") {
                    Text(savePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let creator = torrent.creator {
                LabeledContent("Created By", value: creator)
            }

            if let comment = torrent.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Files

    private func filesSection(_ torrent: TorrentTaskModel) -> some View {
        Section("Files") {
            Menu {
                Button("Normal Priority") { viewModel.setAllFilesPriority(torrentID, priority: .defaultPriority) }
                Button("High Priority") { viewModel.setAllFilesPriority(torrentID, priority: .topPriority) }
                Button("Low Priority") { viewModel.setAllFilesPriority(torrentID, priority: .lowPriority) }
                Button("Don't Download", role: .destructive) { viewModel.setAllFilesPriority(torrentID, priority: .dontDownload) }
            } label: {
                Label("Apply to All Files", systemImage: "slider.horizontal.3")
            }

            ForEach(torrent.files) { file in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Menu {
                            Button("Normal") { viewModel.setFilePriority(torrentID, index: file.index, priority: .defaultPriority) }
                            Button("High") { viewModel.setFilePriority(torrentID, index: file.index, priority: .topPriority) }
                            Button("Low") { viewModel.setFilePriority(torrentID, index: file.index, priority: .lowPriority) }
                            Button("Don't Download", role: .destructive) { viewModel.setFilePriority(torrentID, index: file.index, priority: .dontDownload) }
                        } label: {
                            Text(priorityTitle(file.priority))
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(priorityColor(file.priority))
                                .clipShape(Capsule())
                        }
                    }

                    if file.size > 0 {
                        HStack(spacing: 8) {
                            ProgressView(value: file.progress)
                                .tint(Color.accentColor)

                            Text("\(TorrentByteFormatter.string(file.downloaded)) / \(TorrentByteFormatter.string(file.size))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Trackers

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

            if torrent.trackers.isEmpty {
                Text("No trackers yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(torrent.trackers) { tracker in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tracker.url)
                        .font(.caption)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Text(trackerStateTitle(tracker.state))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(trackerStateColor(tracker.state))

                        if tracker.hasSwarmStats {
                            Text("Seeds \(max(0, tracker.seeds)) · Peers \(max(0, tracker.peers)) · Leechers \(max(0, tracker.leeches))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let next = tracker.nextAnnounceTime {
                            Text("Next announce \(next.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let message = tracker.message, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
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

    // MARK: - Download Options

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

    // MARK: - Speed Limits

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

    // MARK: - Actions

    private func actionsSection(_ torrent: TorrentTaskModel) -> some View {
        Section {
            if torrent.isPaused || torrent.state == .storageError {
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

    private func etaText(_ torrent: TorrentTaskModel) -> String {
        guard let eta = torrent.eta else { return "—" }
        return TorrentByteFormatter.eta(eta)
    }

    private func priorityTitle(_ priority: FileEntry.Priority) -> String {
        switch priority {
        case .dontDownload: return "Skip"
        case .defaultPriority: return "Normal"
        case .lowPriority: return "Low"
        case .topPriority: return "High"
        }
    }

    private func priorityColor(_ priority: FileEntry.Priority) -> Color {
        switch priority {
        case .dontDownload: return Color.red.opacity(0.15)
        case .topPriority: return Color.green.opacity(0.15)
        case .lowPriority: return Color.orange.opacity(0.15)
        case .defaultPriority: return Color.blue.opacity(0.15)
        }
    }

    private func trackerStateTitle(_ state: TorrentTracker.State) -> String {
        switch state {
        case .notContacted: return "Not contacted"
        case .working: return "Working"
        case .updating: return "Announcing"
        case .notWorking: return "Not working"
        case .trackerError: return "Tracker error"
        case .unreachable: return "Unreachable"
        }
    }

    private func trackerStateColor(_ state: TorrentTracker.State) -> Color {
        switch state {
        case .notContacted: return .secondary
        case .working: return .green
        case .updating: return .blue
        case .notWorking: return .orange
        case .trackerError: return .red
        case .unreachable: return .orange
        }
    }
}