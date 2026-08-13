import SwiftUI
import AVKit
import AVFoundation
import Combine

/// Minimal in-app media player for Directory Mode.
///
/// FluxDL has no media engine today, so this is a native AVPlayer sheet with
/// playlist support and per-file position restore. Like WKWebView page loads,
/// AVPlayer media streams cannot be routed through the URLSession proxy — a
/// note is shown when the proxy is active (same documented limitation as web
/// page loads in WebViewContainer).
public struct DirectoryMediaPlayerView: View {
    @ObservedObject var viewModel: DirectoryBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    private let item: DirectoryItem
    private let playlist: [DirectoryItem]

    @State private var player: AVPlayer?
    @State private var currentIndex: Int

    private var statusCancellable: AnyCancellable?
    private var endNotificationCancellable: AnyCancellable?

    private static let positionKeyPrefix = "fluxdl_media_pos_"

    public init(viewModel: DirectoryBrowserViewModel, request: DirectoryPlaybackRequest) {
        self.viewModel = viewModel
        self.item = request.item
        self.playlist = request.playlist
        _currentIndex = State(initialValue: Self.indexOf(request.item, in: request.playlist))
    }

    private static func indexOf(_ item: DirectoryItem, in playlist: [DirectoryItem]) -> Int {
        guard let index = playlist.firstIndex(where: { $0.id == item.id }) else { return 0 }
        return index
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if viewModel.isProxied {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Media streams bypass the proxy (AVPlayer limitation). Use the web browser or download for proxied playback.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                }

                GeometryReader { geo in
                    if let player {
                        VideoPlayerContainer(player: player)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing playback…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if playlist.count > 1 {
                    playlistStrip
                }
            }
            .navigationTitle(currentItem.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { setUpPlayer() }
            .onDisappear {
                savePosition()
                player?.pause()
            }
            .onChange(of: currentIndex) { _ in
                savePosition()
                loadCurrentItem(autoplay: true)
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Playlist

    private var currentItem: DirectoryItem {
        playlist.indices.contains(currentIndex) ? playlist[currentIndex] : item
    }

    private var playlistStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(playlist.enumerated()), id: \.element.id) { index, item in
                    Button {
                        if index != currentIndex {
                            currentIndex = index
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: index == currentIndex ? "play.circle.fill" : "play.circle")
                                .font(.caption)
                            Text(item.name)
                                .font(.caption.weight(index == currentIndex ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            index == currentIndex ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                            in: Capsule()
                        )
                        .foregroundStyle(index == currentIndex ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Player lifecycle

    private func setUpPlayer() {
        player = AVPlayer()
        observeEndOfPlaylist()
        loadCurrentItem(autoplay: true)
    }

    private func loadCurrentItem(autoplay: Bool) {
        guard let player else { return }
        let current = currentItem
        let newItem = AVPlayerItem(url: current.url)
        statusCancellable = newItem.publisher(for: \.status)
            .sink { [weak self] status in
                guard status == .failed, let error = newItem.error else { return }
                Task { @MainActor in
                    self?.viewModel.showToast("Playback failed: \(error.localizedDescription)")
                }
            }
        player.replaceCurrentItem(with: newItem)
        if autoplay {
            player.play()
        }
        restorePosition(for: current.url)
    }

    private func observeEndOfPlaylist() {
        endNotificationCancellable = NotificationCenter.default
            .publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.playlist.count > 1, self.currentIndex < self.playlist.count - 1 else { return }
                self.currentIndex += 1
            }
    }

    private func restorePosition(for url: URL) {
        let key = Self.positionKey(for: url)
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let player = self?.player else { return }
            let time = CMTime(seconds: saved, preferredTimescale: 600)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func savePosition() {
        guard let player, let current = player.currentItem else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        guard seconds.isFinite, seconds > 1 else { return }
        if let urlAsset = current.asset as? AVURLAsset {
            UserDefaults.standard.set(seconds, forKey: Self.positionKey(for: urlAsset.url))
        }
    }

    private static func positionKey(for url: URL) -> String {
        positionKeyPrefix + url.absoluteString
    }
}

/// AVPlayerViewController bridge — gives us native full-screen-capable
/// playback controls.
public struct VideoPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    public func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}