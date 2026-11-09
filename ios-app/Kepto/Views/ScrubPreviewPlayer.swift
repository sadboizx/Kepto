import AVFoundation
import SwiftUI
import UIKit

/// Custom video player with a scrub preview.
///
/// While the user drags the progress bar, a floating thumbnail shows the
/// frame at that timestamp — cropped from the ingest-generated sprite
/// (GET /api/preview/:id, a tile grid of thumbnails; frame index =
/// floor(seconds / interval)). Items without a sprite (older saves, or a
/// failed sprite step) still show the time bubble while scrubbing.
///
/// Playback streams from R2 via GET /api/play/:id with the Authorization
/// header attached to the AVURLAsset (see ItemDetailView's earlier note:
/// there is no public Swift constant for AVURLAssetHTTPHeaderFieldsKey,
/// so it is passed as the documented literal string).
struct ScrubPreviewPlayer: View {
    let item: Item
    @EnvironmentObject private var viewModel: LibraryViewModel

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0
    /// Pre-cropped sprite cells (one per preview frame), built once when
    /// the sprite loads. The drag handler only picks one by index (O(1)).
    @State private var frames: [UIImage] = []
    @State private var timeObserver: Any?
    /// Mute toggle state (mirrors player.isMuted).
    @State private var isMuted = false

    private var aspectRatio: CGFloat {
        if let width = item.width, let height = item.height,
           width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return 16 / 9
    }

    private var scrubSeconds: Double { scrubFraction * duration }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let player {
                    PlayerView(player: player)
                        .aspectRatio(aspectRatio, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                        .onTapGesture { togglePlay() }
                    if !isPlaying {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.85))
                            .allowsHitTesting(false)
                    }
                } else {
                    ProgressView("Preparing video…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            controlsBar
        }
        .onAppear {
            duration = item.duration ?? 0
            startPlayer()
            Task {
                guard item.hasScrubSprite, let api = viewModel.api else { return }
                guard let sprite = try? await api.fetchSprite(for: item) else { return }
                // Crop all cells once, here — not inside the drag
                // handler. The old code cropped a CGImage on every
                // finger move, so the preview lagged behind the drag.
                frames = Self.cropFrames(
                    sprite: sprite,
                    cols: item.previewCols ?? 0,
                    rows: item.previewRows ?? 0,
                    count: item.previewCount ?? 0
                )
            }
        }
        .onDisappear {
            removeTimeObserver()
            player?.pause()
            player = nil
        }
    }

    // MARK: - Controls

    private var controlsBar: some View {
        VStack(spacing: 6) {
            scrubber
            HStack(spacing: 12) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                }
                Text(formatTime(isScrubbing ? scrubSeconds : currentTime))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16))
                }
            }
        }
    }

    /// Progress bar with a drag gesture. While dragging, a preview popup
    /// floats above the thumb showing the sprite frame at that timestamp.
    private var scrubber: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = isScrubbing ? scrubFraction : (duration > 0 ? currentTime / duration : 0)
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(height: 4)
                // Played portion
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: max(width * fraction, 0), height: 4)
                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .offset(x: max(width * fraction - 6, -6))
                // Preview popup while scrubbing
                if isScrubbing {
                    scrubPreview(at: width)
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        scrubFraction = min(max(value.location.x / width, 0), 1)
                        isScrubbing = false
                        seek(to: scrubFraction * duration)
                    }
            )
        }
        .frame(height: 28)
    }

    /// Floating preview above the scrub thumb: sprite frame + timestamp.
    /// The frame keeps its own aspect (portrait for TikTok) at a fixed
    /// height; the popup is clamped so it never runs off the bar's edges.
    @ViewBuilder
    private func scrubPreview(at barWidth: CGFloat) -> some View {
        let frame = frameImage(for: scrubSeconds)
        let aspect: CGFloat = frame.map { $0.size.width / max($0.size.height, 1.0) } ?? (16.0 / 9.0)
        let imageHeight: CGFloat = 120
        let imageWidth = imageHeight * aspect
        let popupWidth = imageWidth
        let centerX = min(max(barWidth * scrubFraction, popupWidth / 2.0 + 4.0), barWidth - popupWidth / 2.0 - 4.0)
        // Lift the popup so its bottom edge sits just above the bar.
        let lift = (imageHeight + 26) / 2 + 22
        VStack(spacing: 4) {
            if let frame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageWidth, height: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(formatTime(scrubSeconds))
                .font(.caption)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.75))
                .clipShape(Capsule())
        }
        .offset(x: centerX - popupWidth / 2, y: -lift)
    }

    // MARK: - Sprite frame

    /// Crops every sprite cell once (when the sprite loads). The old code
    /// cropped inside the drag handler, so each finger move paid a CGImage
    /// crop + UIImage alloc on the main thread and the preview lagged
    /// behind the finger. Now the drag only picks a pre-cropped frame.
    private static func cropFrames(sprite: UIImage, cols: Int, rows: Int, count: Int) -> [UIImage] {
        guard cols > 0, rows > 0, count > 0, let cg = sprite.cgImage else { return [] }
        let cellWidth = cg.width / cols
        let cellHeight = cg.height / rows
        var out: [UIImage] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let rect = CGRect(x: (index % cols) * cellWidth,
                              y: (index / cols) * cellHeight,
                              width: cellWidth, height: cellHeight)
            guard let cropped = cg.cropping(to: rect) else { continue }
            out.append(UIImage(cgImage: cropped, scale: sprite.scale, orientation: sprite.imageOrientation))
        }
        return out
    }

    /// The pre-cropped frame for the given timestamp.
    /// Frame index = floor(seconds / interval), clamped to the last frame.
    private func frameImage(for seconds: Double) -> UIImage? {
        guard !frames.isEmpty,
              let interval = item.previewInterval, let count = item.previewCount,
              interval > 0, count > 0 else { return nil }
        let index = min(max(Int(seconds / interval), 0), min(count, frames.count) - 1)
        return frames[index]
    }

    // MARK: - Playback

    private func startPlayer() {
        guard player == nil, let api = viewModel.api else { return }
        configureAudioSession()
        let asset = AVURLAsset(
            url: api.playURL(for: item),
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": api.authorizationHeader]]
        )
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
            let total = newPlayer.currentItem?.duration.seconds ?? 0
            if total.isFinite && total > 0 { duration = total }
        }
        newPlayer.play()
        isPlaying = true
    }

    /// Sound fix: the app's default audio session (soloAmbient) obeys the
    /// iPhone's silent switch, so a custom AVPlayerLayer player is silent
    /// whenever the switch is on. (v1's VideoPlayer did not have this
    /// problem because AVPlayerViewController manages the session itself.)
    /// `.playback` makes audio play regardless of the silent switch —
    /// the standard behavior for a video app. Non-fatal if it fails:
    /// the video still plays, just obeying the switch.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Best effort only.
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Replaying from the end restarts the video.
            if duration > 0 && currentTime >= duration - 0.5 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            currentTime = seconds
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// UIView wrapper around AVPlayerLayer (SwiftUI has no native player layer).
private struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

private final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
