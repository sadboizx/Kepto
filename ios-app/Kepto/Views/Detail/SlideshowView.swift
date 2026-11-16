import AVFoundation
import SwiftUI

/// Full-screen auto-advancing slideshow over a list of Kepto `Item`s —
/// Photos' `SlideshowView` (plan row 10), adapted to cloud data.
///
/// Photos' version only shows stills (`requestDisplayImage`); Kepto's
/// adaptation plays videos through and advances when playback ends:
/// - Photos advance on Photos' 2.8s timer, with the Ken Burns zoom
///   (1.06x over 2.6s) while playing.
/// - Videos use the same player setup as `PhotoDetailPage` (AVURLAsset
///   + Bearer header) and advance when the time observer sees the end;
///   a backstop task advances after `duration + 3s` so a stalled or
///   failed video can never freeze the show.
/// - Tap the slide toggles play/pause; the X button (top-left) exits.
///   The show loops back to the first slide, like Photos.
/// - No music: the Photos app's slideshow music comes from the local
///   music library, which Kepto has no access to — dropped, nothing
///   to render. No Editor (Q2).
struct SlideshowView: View {
    let items: [Item]

    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var playing = true
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?

    /// Photos' slide length for stills.
    private static let photoDuration: TimeInterval = 2.8

    private var current: Item? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// True when the current slide is a ready video (the only case
    /// that plays instead of timing out). Computed from the item, not
    /// from the player, so the advance task and the loader agree even
    /// before the player exists.
    private var currentIsVideo: Bool {
        guard let current, current.status == .ready else { return false }
        return current.contentType?.hasPrefix("video/") == true
    }

    /// Restarts the advance task whenever the slide or the play state
    /// changes; the old task is cancelled by SwiftUI.
    private var slideTaskID: String { "\(index)-\(playing)" }

    var body: some View {
        ZStack {
            // Media layer: the tap gesture lives here (not on the
            // outer ZStack) so taps on the top-bar buttons — siblings
            // in the overlay below — never also toggle play/pause.
            ZStack {
                Color.black.ignoresSafeArea()
                if let current {
                    if currentIsVideo {
                        if let player {
                            PlayerView(player: player)
                        } else {
                            ProgressView().tint(.white)
                        }
                    } else if current.status == .ready {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .scaleEffect(playing ? 1.06 : 1)
                                .animation(.easeInOut(duration: 2.6), value: index)
                                .id(index)
                        } else {
                            ProgressView().tint(.white)
                        }
                    } else if current.status == .pending {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.red)
                            Text(current.friendlyIngestError)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .onTapGesture {
                togglePlaying()
            }

            // Overlay: top bar + centre play button for a paused
            // video. A sibling of the media layer, so its buttons
            // never trigger the media tap gesture.
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .accessibilityLabel(L10n.cancel)
                    Spacer()
                    Text("\(min(index + 1, max(items.count, 1))) / \(items.count)")
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    Button {
                        togglePlaying()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .accessibilityLabel(playing ? L10n.pause : L10n.play)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if currentIsVideo, !playing, player != nil {
                    Button {
                        togglePlaying()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .padding(18)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(L10n.play)
                }
                Spacer()
            }
        }
        .onAppear { loadCurrent() }
        .onChange(of: index) { _, _ in loadCurrent() }
        .onChange(of: playing) { _, isPlaying in
            if isPlaying {
                resumeVideo()
            } else {
                player?.pause()
            }
        }
        .onDisappear { teardownPlayer() }
        .task(id: slideTaskID) {
            guard playing, items.count > 1 else { return }
            // Still: Photos' 2.8s. Video: the time observer advances
            // on the natural end; this is only a backstop so a
            // stalled/failed video can never freeze the show.
            let wait: TimeInterval
            if currentIsVideo {
                wait = (current?.duration ?? 30) + 3
            } else {
                wait = Self.photoDuration
            }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, playing else { return }
            advance()
        }
        .statusBarHidden(true)
    }

    private func togglePlaying() {
        playing.toggle()
        Haptics.select()
    }

    private func advance() {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            index = (index + 1) % items.count
        }
    }

    // MARK: - Loading

    private func loadCurrent() {
        teardownPlayer()
        guard let current else { return }
        if currentIsVideo {
            setupPlayer()
            if playing { player?.play() }
        } else if current.status == .ready {
            Task {
                guard let api = viewModel.api else { return }
                if let loaded = try? await api.fetchThumbnail(id: current.id) {
                    // Only keep it if we are still on this slide.
                    if items.indices.contains(index), items[index].id == current.id {
                        image = loaded
                    }
                }
            }
        }
    }

    // MARK: - Player (PhotoDetailPage's setup, reused as-is)

    private func setupPlayer() {
        guard player == nil, let api = viewModel.api,
              let current, current.status == .ready, currentIsVideo else { return }
        configureAudioSession()
        let asset = AVURLAsset(
            url: api.playURL(for: current),
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": api.authorizationHeader]]
        )
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.actionAtItemEnd = .none
        player = newPlayer
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
            guard let newPlayer, playing, items.count > 1 else { return }
            let total = newPlayer.currentItem?.duration.seconds ?? 0
            guard total.isFinite, total > 0 else { return }
            if time.seconds >= total - 0.15 {
                advance()
            }
        }
    }

    /// Resume a paused video from where it stopped (restart from the
    /// top if it already ended).
    private func resumeVideo() {
        guard let player, currentIsVideo else { return }
        let total = player.currentItem?.duration.seconds ?? 0
        if total > 0, player.currentTime().seconds >= total - 0.5 {
            player.seek(to: .zero)
        }
        player.play()
    }

    private func teardownPlayer() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    /// Sound fix (same as the detail player): the app's default audio
    /// session (soloAmbient) obeys the iPhone's silent switch, so a
    /// custom AVPlayerLayer player is silent whenever the switch is on.
    /// `.playback` makes audio play regardless of the silent switch.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Best effort only.
        }
    }
}
