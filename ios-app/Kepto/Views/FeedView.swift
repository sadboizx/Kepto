import AVFoundation
import SwiftUI
import UIKit

/// TikTok-style full-screen video feed: one video at a time, full-width
/// 9:16, swipe up/down for the next video. The home screen's video
/// sections (Tất cả / Reels / Bài viết) and search results are shown
/// here instead of a grid; a collection's videos open here too.
///
/// Each page owns its AVPlayer: created when the page appears, played
/// only while it is the current page, released when it disappears.
/// Videos loop. A thin progress bar sits at the very bottom edge (drag
/// to scrub, with the sprite preview popup). The background is black
/// throughout; the video is aspect-fit, never cropped. Photo posts
/// show the full image instead of a player.
struct FeedView: View {
    /// The list to page through. A Binding so appends from `onNearEnd`
    /// (the library's loadMore, or a collection's) are visible here.
    @Binding var items: [Item]
    /// The item the feed opens on.
    let startItemId: String
    /// Called when the user nears the end (loads the next page).
    var onNearEnd: (() async -> Void)? = nil
    /// Shows a close (X) button top-left. True when the feed is a
    /// full-screen cover (e.g. opened from a collection); the home
    /// feed is the root screen and has no close button.
    var showCloseButton: Bool = false

    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentItemId: String
    @State private var showingActionSheet = false
    @State private var showingDetail = false
    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?

    init(items: Binding<[Item]>, startItemId: String,
         onNearEnd: (() async -> Void)? = nil, showCloseButton: Bool = false) {
        self._items = items
        self.startItemId = startItemId
        self.onNearEnd = onNearEnd
        self.showCloseButton = showCloseButton
        self._currentItemId = State(initialValue: startItemId)
    }

    private var currentIndex: Int? { items.firstIndex { $0.id == currentItemId } }
    private var currentItem: Item? { currentIndex.flatMap { items[$0] } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                emptyState
            } else {
                feedPages
            }
            if showCloseButton {
                closeButton
            }
            if currentItem != nil {
                moreButton
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Video", isPresented: $showingActionSheet, titleVisibility: .hidden) {
            Button("Chi tiết") { showingDetail = true }
            Button("Xóa", role: .destructive) { showingDeleteConfirmation = true }
            Button("Hủy", role: .cancel) {}
        }
        .confirmationDialog("Delete this saved item?",
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteCurrentItem() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved copy from the cloud. The original post is not affected.")
        }
        .sheet(isPresented: $showingDetail) {
            detailSheet
        }
        .alert("Delete failed", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Empty state when there is nothing to page through.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here", systemImage: "tray")
        } description: {
            Text("No videos to show.")
        }
    }

    /// The paging scroll view: one full-screen page per video.
    /// (Split out of `body`: the whole feed in one expression made
    /// the compiler give up type-checking it in reasonable time.)
    private var feedPages: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    FeedVideoPage(item: item, isCurrent: item.id == currentItemId)
                        .id(item.id)
                        .containerRelativeFrame(.vertical)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentItemId)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .onChange(of: currentItemId) { _, _ in handleCurrentItemChange() }
        .onChange(of: items) { oldItems, newItems in handleItemsChange(old: oldItems, new: newItems) }
        .task { fixInitialCurrentItem() }
    }

    /// Close button (covers only, top-left).
    private var closeButton: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
                .padding(.leading, 16)
                Spacer()
            }
            Spacer()
        }
    }

    /// "..." rail button (right edge, vertically centred):
    /// details / delete for the current video.
    private var moreButton: some View {
        HStack {
            Spacer()
            Button {
                showingActionSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .padding(.trailing, 12)
        }
        .frame(maxHeight: .infinity)
    }

    /// Detail sheet for the current video.
    @ViewBuilder
    private var detailSheet: some View {
        if let currentItem {
            NavigationStack {
                ItemDetailView(item: currentItem)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showingDetail = false
                            } label: {
                                Label("Close", systemImage: "xmark")
                            }
                        }
                    }
            }
        }
    }

    /// Near the end: load the next page so swiping never hits a dead
    /// end while there is more to show.
    private func handleCurrentItemChange() {
        if let idx = currentIndex, items.count - idx <= 3 {
            Task { await onNearEnd?() }
        }
    }

    /// The current item vanished (e.g. deleted): move to the nearest
    /// remaining video instead of a blank page.
    private func handleItemsChange(old oldItems: [Item], new newItems: [Item]) {
        guard !newItems.contains(where: { $0.id == currentItemId }) else { return }
        if let oldIdx = oldItems.firstIndex(where: { $0.id == currentItemId }) {
            let nextIdx = min(oldIdx, newItems.count - 1)
            if nextIdx >= 0 { currentItemId = newItems[nextIdx].id }
        } else if let last = newItems.last {
            currentItemId = last.id
        }
    }

    /// If the feed opened on an id that is not in the list, start at
    /// the first video.
    private func fixInitialCurrentItem() {
        if !items.contains(where: { $0.id == currentItemId }),
           let first = items.first {
            currentItemId = first.id
        }
    }

    private func deleteCurrentItem() async {
        guard let currentItem else { return }
        do {
            try await viewModel.delete(item: currentItem)
        } catch {
            deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// One full-screen page in the feed: the video (or photo) on a black
/// background, aspect-fit so it is never cropped. The player is created
/// on appear, plays only while this page is the current one, loops, and
/// is released on disappear. Tap toggles play/pause (with a brief
/// centre icon). A thin progress bar sits at the very bottom edge.
private struct FeedVideoPage: View {
    let item: Item
    let isCurrent: Bool
    @EnvironmentObject private var viewModel: LibraryViewModel

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var sprite: UIImage?
    @StateObject private var frameCache = ScrubPreviewPlayer.SpriteFrameCache()
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var tapIcon: String?
    @State private var tapIconTask: Task<Void, Never>?
    @State private var fullImage: UIImage?

    private var isImage: Bool { item.contentType?.hasPrefix("image/") == true }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if item.status == .ready, !isImage {
                        if let player {
                            PlayerView(player: player)
                        } else {
                            ProgressView().tint(.white)
                        }
                    } else if item.status == .ready, isImage {
                        if let fullImage {
                            Image(uiImage: fullImage)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView().tint(.white)
                        }
                    } else if item.status == .pending {
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Đang xử lý…")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.red)
                            Text(item.friendlyIngestError)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    if let tapIcon {
                        Image(systemName: tapIcon)
                            .font(.system(size: 72))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard item.status == .ready, !isImage else { return }
                    togglePlay()
                }
                if item.status == .ready, !isImage {
                    FeedProgressBar(
                        currentTime: currentTime,
                        duration: duration,
                        isScrubbing: $isScrubbing,
                        item: item,
                        sprite: sprite,
                        frameCache: frameCache,
                        onSeek: { seconds in seek(to: seconds) }
                    )
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 8))
                }
            }
        }
        .background(Color.black)
        .onAppear {
            setupPlayer()
            if isImage, item.status == .ready {
                Task { await loadFullImage() }
            }
            Task {
                guard item.hasScrubSprite, let api = viewModel.api else { return }
                sprite = try? await api.fetchSprite(for: item)
            }
        }
        .onDisappear { teardownPlayer() }
        .onChange(of: isCurrent) { _, current in
            if current {
                if player == nil { setupPlayer() }
                player?.play()
                isPlaying = true
            } else {
                player?.pause()
                isPlaying = false
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                player?.pause()
            } else if isCurrent {
                player?.play()
                isPlaying = true
            }
        }
    }

    private func setupPlayer() {
        guard player == nil, let api = viewModel.api,
              item.status == .ready, !isImage else { return }
        configureAudioSession()
        let asset = AVURLAsset(
            url: api.playURL(for: item),
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": api.authorizationHeader]]
        )
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.actionAtItemEnd = .none
        player = newPlayer
        // Loop: TikTok replays the video when it ends.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
            let total = newPlayer.currentItem?.duration.seconds ?? 0
            if total.isFinite && total > 0 { duration = total }
        }
        if isCurrent {
            newPlayer.play()
            isPlaying = true
        }
    }

    private func teardownPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        tapIconTask?.cancel()
        tapIcon = nil
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

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            flashIcon("pause.fill")
        } else {
            if duration > 0 && currentTime >= duration - 0.5 { seek(to: 0) }
            player.play()
            isPlaying = true
            flashIcon("play.fill")
        }
    }

    private func flashIcon(_ name: String) {
        tapIconTask?.cancel()
        tapIcon = name
        tapIconTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            tapIcon = nil
        }
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            currentTime = seconds
        }
    }

    /// Photo posts: the thumbnail is the full-resolution image (the
    /// ingest saves one full frame, unscaled), so it is the image to show.
    private func loadFullImage() async {
        guard fullImage == nil, let api = viewModel.api else { return }
        fullImage = try? await api.fetchThumbnail(id: item.id)
    }
}

/// Thin progress bar at the very bottom edge of a feed page (TikTok
/// style): a 2pt line — track white 30%, played portion white.
/// Dragging scrubs; while dragging, a preview popup (sprite frame at
/// that timestamp + time) floats above the bar. The touch area is
/// taller than the visible line so it is easy to grab.
private struct FeedProgressBar: View {
    let currentTime: Double
    let duration: Double
    @Binding var isScrubbing: Bool
    let item: Item
    let sprite: UIImage?
    let frameCache: ScrubPreviewPlayer.SpriteFrameCache
    let onSeek: (Double) -> Void

    @State private var scrubFraction: Double = 0
    @State private var dragX: CGFloat = 0

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: geo.size.width * (isScrubbing ? scrubFraction : progress))
                }
                .frame(height: 2)
            }
            .frame(height: 28, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        scrubFraction = fraction
                        dragX = value.location.x
                        isScrubbing = true
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        isScrubbing = false
                        onSeek(fraction * duration)
                    }
            )
            .overlay(alignment: .bottomLeading) {
                if isScrubbing, let frame = frameImage(for: scrubFraction * duration) {
                    scrubPopup(frame: frame, in: geo.size.width)
                }
            }
        }
        .frame(height: 28)
    }

    /// Preview popup: the sprite frame at the scrub timestamp + the
    /// time, floating above the bar and centred on the finger (clamped
    /// to the screen edges).
    private func scrubPopup(frame: UIImage, in width: CGFloat) -> some View {
        let popupWidth: CGFloat = 120
        let aspect = frame.size.width / max(frame.size.height, 1)
        let frameHeight = popupWidth / aspect
        let half = popupWidth / 2
        let centerX = min(max(dragX, half + 8), width - half - 8)
        return VStack(spacing: 4) {
            Image(uiImage: frame)
                .resizable()
                .scaledToFit()
                .frame(width: popupWidth, height: frameHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(formatTime(scrubFraction * duration))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.7))
                .clipShape(Capsule())
        }
        .offset(x: centerX - half, y: -10)
    }

    /// The sprite cell for the given timestamp (cropped on first use,
    /// then cached — see SpriteFrameCache).
    private func frameImage(for seconds: Double) -> UIImage? {
        guard let sprite,
              let cols = item.previewCols, let rows = item.previewRows,
              let interval = item.previewInterval, let count = item.previewCount,
              cols > 0, rows > 0, interval > 0, count > 0 else { return nil }
        let index = min(max(Int(seconds / interval), 0), count - 1)
        return frameCache.frame(at: index, from: sprite, cols: cols, rows: rows)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
