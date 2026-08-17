import SwiftUI
import AVKit
import AVFoundation
import Combine

/// Playback session for one media sheet presentation. A reference type on
/// purpose: it owns the AVPlayer and Combine subscriptions, so the SwiftUI
/// view stays a plain immutable struct.
@MainActor
public final class DirectoryPlayerSession: ObservableObject {
    @Published public private(set) var currentIndex: Int
    public let player = AVPlayer()
    public let playlist: [DirectoryItem]

    private let onFailure: (String) -> Void
    private var statusCancellable: AnyCancellable?
    private var endCancellable: AnyCancellable?

    private static let positionKeyPrefix = "fluxdl_media_pos_"

    public init(
        playlist: [DirectoryItem],
        initialIndex: Int,
        onFailure: @escaping (String) -> Void
    ) {
        self.playlist = playlist
        self.currentIndex = min(max(initialIndex, 0), max(playlist.count - 1, 0))
        self.onFailure = onFailure
        observeEndOfPlaylist()
        loadCurrentItem(autoplay: true)
    }

    public var currentItem: DirectoryItem {
        playlist[currentIndex]
    }

    public func select(index: Int) {
        guard playlist.indices.contains(index), index != currentIndex else { return }
        savePosition()
        currentIndex = index
        loadCurrentItem(autoplay: true)
    }

    public func savePosition() {
        guard let current = player.currentItem else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        guard seconds.isFinite, seconds > 1 else { return }
        if let urlAsset = current.asset as? AVURLAsset {
            UserDefaults.standard.set(seconds, forKey: Self.positionKey(for: urlAsset.url))
        }
    }

    public func restorePosition(for url: URL) {
        let saved = UserDefaults.standard.double(forKey: Self.positionKey(for: url))
        guard saved > 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            let time = CMTime(seconds: saved, preferredTimescale: 600)
            await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func loadCurrentItem(autoplay: Bool) {
        let current = currentItem
        let newItem = AVPlayerItem(url: current.url)
        statusCancellable = newItem.publisher(for: \.status)
            .sink { [weak self] status in
                guard status == .failed, let error = newItem.error else { return }
                self?.onFailure(error.localizedDescription)
            }
        player.replaceCurrentItem(with: newItem)
        if autoplay {
            player.play()
        }
        restorePosition(for: current.url)
    }

    private func observeEndOfPlaylist() {
        endCancellable = NotificationCenter.default
            .publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.playlist.count > 1, self.currentIndex < self.playlist.count - 1 else { return }
                self.currentIndex += 1
                self.loadCurrentItem(autoplay: true)
            }
    }

    private static func positionKey(for url: URL) -> String {
        positionKeyPrefix + url.absoluteString
    }
}

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
    @StateObject private var session: DirectoryPlayerSession

    public init(viewModel: DirectoryBrowserViewModel, request: DirectoryPlaybackRequest) {
        self.viewModel = viewModel
        let playlist = request.playlist
        let initialIndex = DirectoryMediaPlayerView.indexOf(request.item, in: playlist)
        _session = StateObject(wrappedValue: DirectoryPlayerSession(
            playlist: playlist,
            initialIndex: initialIndex,
            onFailure: { message in viewModel.showToast("Playback failed: \(message)") }
        ))
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
                    VideoPlayerContainer(player: session.player)
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                if session.playlist.count > 1 {
                    playlistStrip
                }
            }
            .navigationTitle(session.currentItem.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear {
                session.savePosition()
                session.player.pause()
            }
        }
        .presentationDetents([.large])
    }

    private var playlistStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(session.playlist.enumerated()), id: \.element.id) { index, item in
                    Button {
                        session.select(index: index)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: index == session.currentIndex ? "play.circle.fill" : "play.circle")
                                .font(.caption)
                            Text(item.name)
                                .font(.caption.weight(index == session.currentIndex ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            index == session.currentIndex ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                            in: Capsule()
                        )
                        .foregroundStyle(index == session.currentIndex ? .white : .primary)
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