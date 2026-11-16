import AVFoundation
import SwiftUI
import UIKit

/// TikTok-style full-screen video viewer: one video at a time,
/// full-width, swipe up/down for the next video. Opened from a grid
/// (the home screen or a collection) — the home itself is a grid, not
/// a feed. The video fills the whole screen edge-to-edge
/// (`.resizeAspectFill`, TikTok-style: top under the status bar,
/// bottom to the screen edge, sides cropped slightly on a tall
/// screen). The username and caption overlay the video at the
/// bottom-left, right at the bottom edge just above the Home
/// Indicator, and the progress bar sits right above the username.
/// The status bar text is white over the video.
///
/// Each page owns its AVPlayer: created when the page appears, played
/// only while it is the current page. The player is KEPT (paused) when
/// the page scrolls away — destroying and recreating it on every swipe
/// is what left the next video with sound but no picture (the player
/// was already playing when its new layer was created, and the layer
/// never picked up the video track). Playback is scheduled a beat
/// after the page becomes current, and seeks to the current frame
/// first, so the layer always renders a fresh frame. Videos loop.
/// A thin progress bar sits above the username (drag to scrub,
/// with the sprite preview popup). The background is black throughout.
/// Photo posts show the full image instead of a player.
///
/// Video actions: a "…" button at the top-right corner
/// (Facebook-style header position; Save to Photos, Share,
/// Favorite, Add to Album, Delete) and a running-person
/// (figure.run) button at the bottom-right corner for playback
/// speed. No long-press menu. No Share-with / Repost / friends list.
struct FeedView: View {
    /// The list to page through. A Binding so appends from `onNearEnd`
    /// (the library's loadMore, or a collection's) are visible here.
    @Binding var items: [Item]
    /// The item the feed opens on.
    let startItemId: String
    /// Called when the user nears the end (loads the next page).
    var onNearEnd: (() async -> Void)? = nil

    @EnvironmentObject private var viewModel: LibraryViewModel

    /// The id of the page the feed is showing. Optional because
    /// `.scrollPosition(id:)` needs a `Binding<String?>`.
    @State private var currentItemId: String?
    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?
    /// The video a "…" menu Delete is about to delete (captured when
    /// the user taps Delete, so a swipe in between cannot retarget it).
    @State private var itemPendingDelete: Item?
    /// True while the user is dragging a page's progress bar. The
    /// paging ScrollView is disabled while this is true, so a scrub
    /// drag that drifts slightly vertical cannot be stolen mid-drag
    /// and turn into a page swipe (the bar "missing"). Lifted here
    /// from FeedVideoPage because the ScrollView lives in this view.
    @State private var isScrubbing = false

    init(items: Binding<[Item]>, startItemId: String,
         onNearEnd: (() async -> Void)? = nil) {
        self._items = items
        self.startItemId = startItemId
        self.onNearEnd = onNearEnd
        self._currentItemId = State(initialValue: startItemId)
    }

    private var currentIndex: Int? { items.firstIndex { $0.id == currentItemId } }
    private var currentItem: Item? { currentIndex.flatMap { items[$0] } }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if items.isEmpty {
                    emptyState
                } else {
                    feedPages
                }
            }
            // Native back gesture (interactive pop) + paging ScrollView:
            // the paging ScrollView claims the touch, so the navigation
            // controller's edge pan never fires on its own. The
            // NativePopGestureHelper below (a UIKit bridge) makes the
            // scroll view's pan wait for the edge pan, so a rightward
            // swipe from the left edge pops with the NATIVE gesture
            // (interactive transition, follows the finger, cancels
            // mid-swipe) while vertical swipes still page the feed.
            // The old custom DragGesture (v37/v39) is removed — it
            // would fight the native gesture for the same drag.
            .background(NativePopGestureHelper())
        }
        .preferredColorScheme(.dark)
        // Full-screen player: hide the navigation bar (no back
        // button/title) and the tab bar, so the video fills the
        // whole screen exactly like the old full-screen cover did.
        // The native back gesture still works with both hidden.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .confirmationDialog("Delete this saved item?",
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteCurrentItem() }
            }
            Button("Cancel", role: .cancel) { itemPendingDelete = nil }
        } message: {
            Text("This removes the saved copy from the cloud. The original post is not affected.")
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
    /// The scroll view itself is split further (`feedScrollView` +
    /// `feedPageRow`): the full ScrollViewReader + ScrollView +
    /// ForEach + FeedVideoPage expression in one piece again exceeded
    /// the compiler's type-check budget (build run 42695574595,
    /// v26) after the @Binding isScrubbing + .scrollDisabled were
    /// added. Each piece is now inferred on its own.
    private var feedPages: some View {
        ScrollViewReader { proxy in
            feedScrollView
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentItemId)
                .scrollIndicators(.hidden)
                // While a progress-bar scrub is in progress the feed must
                // not page: a scrub drag that drifts slightly vertical
                // would otherwise be stolen mid-drag and the bar "misses".
                .scrollDisabled(isScrubbing)
                .ignoresSafeArea()
                .onChange(of: currentItemId) { _, _ in handleCurrentItemChange() }
                .onChange(of: items) { oldItems, newItems in handleItemsChange(old: oldItems, new: newItems) }
                .task { fixInitialCurrentItem() }
                .task { await scrollToStartItem(proxy: proxy) }
        }
    }

    /// The scroll view without its behavior/lifecycle modifiers.
    private var feedScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    feedPageRow(for: item)
                }
            }
            .scrollTargetLayout()
        }
    }

    /// One page of the feed. (Argument order matters: the memberwise
    /// init follows the property order — `onDeleteRequest` is declared
    /// before the `isScrubbing` binding — so onDeleteRequest must come
    /// first here. The v25 call had them swapped, which the v26
    /// type-check timeout had been masking; v27's split exposed it.)
    private func feedPageRow(for item: Item) -> some View {
        FeedVideoPage(item: item, isCurrent: item.id == currentItemId, onDeleteRequest: { video in
            itemPendingDelete = video
            showingDeleteConfirmation = true
        }, isScrubbing: $isScrubbing)
            .id(item.id)
            .containerRelativeFrame(.vertical)
    }

    /// The feed must open on the video the user tapped, not the first
    /// one. `.scrollPosition` does not always apply its initial value
    /// on first layout (the target page may not be laid out yet in the
    /// LazyVStack), so scroll to the start item explicitly once the
    /// layout settles.
    private func scrollToStartItem(proxy: ScrollViewProxy) async {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        if items.contains(where: { $0.id == startItemId }) {
            proxy.scrollTo(startItemId, anchor: .top)
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
        guard let target = itemPendingDelete ?? currentItem else { return }
        itemPendingDelete = nil
        do {
            try await viewModel.delete(item: target)
            // Also drop it from this feed's list: when the feed was
            // opened from a collection, the view model's list is a
            // different array, so the deleted page would otherwise stay
            // on screen. Removing it here moves the feed to the nearest
            // remaining video (see `handleItemsChange`).
            items.removeAll { $0.id == target.id }
        } catch {
            deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// One full-screen page in the feed: the video (or photo) filling
/// the screen edge-to-edge (`.resizeAspectFill`, TikTok-style), the
/// username and caption overlaid bottom-left on the video at the
/// very bottom edge, and the progress bar right above the username.
/// The player is created on appear and kept (paused)
/// when the page scrolls away — see the note on `schedulePlay`
/// for why it is not destroyed. It plays only while this page is
/// the current one, and loops. There is no long-press menu: a
/// "…" button sits at the top-right corner (Save to Photos,
/// Share, Favorite, Add to Album, Delete) and a running-person
/// button at the bottom-right corner opens the playback speed
/// menu. The username and caption are overlaid on
/// the video itself, not repeated in the menu.
private struct FeedVideoPage: View {
    let item: Item
    let isCurrent: Bool
    /// Called when the user taps Delete in the "…" menu (the
    /// feed shows the delete confirmation for this video).
    var onDeleteRequest: ((Item) -> Void)? = nil
    @EnvironmentObject private var viewModel: LibraryViewModel

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    /// Bound to FeedView: true while the user drags this page's
    /// progress bar. FeedView disables the paging ScrollView while
    /// it is true, so a scrub cannot be stolen mid-drag.
    @Binding var isScrubbing: Bool
    @State private var sprite: UIImage?
    @StateObject private var frameCache = ScrubPreviewPlayer.SpriteFrameCache()
    @State private var timeObserver: Any?
    @State private var tapIcon: String?
    @State private var tapIconTask: Task<Void, Never>?
    /// Deferred play (see `schedulePlay`): cancelled when the page
    /// stops being current or disappears.
    @State private var playTask: Task<Void, Never>?
    @State private var fullImage: UIImage?
    /// Playback speed from the running-person button (1.0 = normal).
    @State private var playbackRate: Float = 1.0
    /// Speeds offered by the running-person button's menu.
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    /// Mute state for this page's player (speaker icon in the
    /// toolbar). Per-page — a new video starts with sound.
    @State private var isMuted = false
    /// The Photos-style info sheet (the (i) button in the toolbar).
    @State private var showingInfo = false
    /// The "…" menu's "Add to Album" picker (nil = closed).
    @State private var showingAlbumPicker = false
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// Set when this page becomes current after a swipe: the next
    /// playCurrent starts from 0 (TikTok restarts the video every time
    /// you land on it) instead of resuming where the kept player left
    /// off. Cleared by playCurrent once it seeks to 0.
    @State private var restartFromStart = false
    /// Facebook Reels-style progress bar visibility: the bar shows
    /// while the user interacts, then fades out after 2.5s idle.
    /// Starts visible when the page becomes current.
    @State private var controlsVisible: Bool = true
    /// The auto-hide timer for the progress bar (cancelled and
    /// restarted on every interaction).
    @State private var hideControlsTask: Task<Void, Never>?
    /// Short notice above the progress bar (e.g. "Đã lưu vào Photos").
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private var isImage: Bool { item.contentType?.hasPrefix("image/") == true }

    var body: some View {
        GeometryReader { geo in
            // TikTok layout: the video fills the whole screen
            // edge-to-edge (top under the status bar, bottom to the
            // screen edge). The username/caption overlay the video
            // at the bottom-left, right at the bottom edge just
            // above the Home Indicator, and the progress bar sits
            // right above the username.
            ZStack {
                Color.black
                if item.status == .ready, !isImage {
                    if let player {
                        PlayerView(player: player, videoGravity: .resizeAspectFill)
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
                // Bottom gradient so the toolbar icons stay legible
                // over the video (Photos-style).
                if item.status == .ready {
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 180)
                    }
                }
                // Username + caption, overlaid bottom-left on the
                // video (TikTok-style), directly above the progress
                // bar. The running-person (playback speed) button
                // sits to the right of this text, so nothing covers
                // it; the "…" button is at the top-right corner.
                // Progress bar sits ABOVE the username (not at the
                // very bottom): the username is at the bottom edge,
                // just above the Home Indicator, and the progress bar
                // is right above it.
                // Progress bar + Photos-style bottom toolbar. The
                // username/caption overlay is gone (Photos shows
                // media clean). The toolbar sits at the very bottom,
                // just above the Home Indicator, and the progress bar
                // is right above it.
                VStack(spacing: 0) {
                    Spacer()
                    if item.status == .ready, !isImage {
                        FeedProgressBar(
                            currentTime: currentTime,
                            duration: duration,
                            isScrubbing: $isScrubbing,
                            controlsVisible: controlsVisible,
                            item: item,
                            sprite: sprite,
                            frameCache: frameCache,
                            onSeek: { seconds in seekFromScrub(to: seconds) }
                        )
                        // 10pt above the toolbar.
                        .padding(.bottom, 10)
                    }
                    if item.status == .ready {
                        // Photos toolbar: Share, Favorite, then (video
                        // only) Play/Pause, Mute, Speed, then Info,
                        // Delete. Photo: Share, Favorite, Info,
                        // Delete. Blue icons, evenly spread.
                        HStack(spacing: 0) {
                            playerTabButton(systemName: "square.and.arrow.up", label: "Share") {
                                shareItem()
                            }
                            playerTabButton(systemName: item.isFavorite ? "heart.fill" : "heart", label: "Favorite") {
                                Task {
                                    if let updated = await viewModel.toggleFavorite(item: item) {
                                        showNotice(updated.isFavorite ? "Đã thêm vào Favorite" : "Đã bỏ Favorite")
                                    }
                                }
                            }
                            if !isImage {
                                playerTabButton(systemName: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play") {
                                    togglePlay()
                                }
                                playerTabButton(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: isMuted ? "Unmute" : "Mute") {
                                    toggleMute()
                                }
                                // Playback speed (running-person icon)
                                // lives in the toolbar now, not at the
                                // bottom-right corner.
                                Menu {
                                    ForEach(speeds, id: \.self) { rate in
                                        Button {
                                            selectRate(rate)
                                        } label: {
                                            if rate == playbackRate {
                                                Label(String(format: "%gx", rate), systemImage: "checkmark")
                                            } else {
                                                Text(String(format: "%gx", rate))
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "figure.run")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.blue)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .accessibilityLabel("Playback speed")
                                }
                            }
                            playerTabButton(systemName: showingInfo ? "info.circle.fill" : "info.circle", label: "Info") {
                                showingInfo = true
                            }
                            playerTabButton(systemName: "trash", label: "Delete") {
                                onDeleteRequest?(item)
                            }
                        }
                        .padding(.horizontal, 8)
                        // At the very bottom, just above the Home
                        // Indicator (a small gap, not touching it).
                        .padding(.bottom, geo.safeAreaInsets.bottom + 8)
                    }
                }
                // (No top-right "…" menu any more — its actions live
                // in the bottom toolbar now: Share, Favorite,
                // Delete. Save to Photos and Add to Album moved to
                // the info sheet, so they are still reachable from
                // the Player.)
                // Transient notice (Copy link / Download result).
                // Sits above the progress bar (which is now above the
                // username), so it never covers either.
                if let notice {
                    VStack {
                        Spacer()
                        Text(notice)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(.bottom, 160)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard item.status == .ready, !isImage else { return }
                togglePlay()
                // Tapping is an interaction: show the progress bar
                // again, then hide it after a while idle.
                showControlsTemporarily()
            }
            // No long-press context menu any more — the "…" button
            // (top-right corner) opens the menu, and the
            // running-person button (bottom-right) opens the
            // playback speed menu.
        }
        .background(Color.black)
        .sheet(isPresented: $showingAlbumPicker) {
            AddToCollectionPickerView(
                item: item,
                onAddedToCollection: { name, added in
                    showNotice(added ? "Đã thêm vào \(name)" : "Đã có trong \(name)")
                },
                onCancel: { showingAlbumPicker = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.black)
        }
        // Photos-style info sheet (the (i) button in the toolbar).
        .sheet(isPresented: $showingInfo) {
            ItemInfoSheet(
                item: item,
                onSaveToPhotos: { Task { await downloadVideo() } },
                onAddToAlbum: { showingAlbumPicker = true }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(activityItems: [file.url])
        }
        .onAppear {
            setupPlayer()
            if isCurrent {
                // (Re)appearing as the current page: restart from the
                // beginning, same as the isCurrent change above.
                // onAppear covers the case where SwiftUI recreates
                // this page while it is current (onChange does not
                // fire for a freshly created view).
                currentTime = 0
                isScrubbing = false
                restartFromStart = true
                schedulePlay()
                // Show the progress bar briefly, then fade it out.
                showControlsTemporarily()
            }
            if isImage, item.status == .ready {
                Task { await loadFullImage() }
            }
            Task {
                guard item.hasScrubSprite, let api = viewModel.api else { return }
                sprite = try? await api.fetchSprite(for: item)
            }
        }
        .onDisappear {
            // Pause only — the player is KEPT (with its layer and
            // its buffer) so swiping back resumes instantly and the
            // layer never has to re-attach to a playing player.
            // It is released when SwiftUI destroys this page.
            playTask?.cancel()
            player?.pause()
            isPlaying = false
            tapIconTask?.cancel()
            tapIcon = nil
            hideControlsTask?.cancel()
        }
        .onChange(of: isCurrent) { _, current in
            if current {
                // Swipe landed on this page: restart from the
                // beginning (reset the start time to 0 and the scrub
                // preview with it), then play. The kept player would
                // otherwise resume where it left off.
                currentTime = 0
                isScrubbing = false
                restartFromStart = true
                schedulePlay()
                // Show the progress bar briefly, then fade it out.
                showControlsTemporarily()
            } else {
                playTask?.cancel()
                player?.pause()
                isPlaying = false
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                player?.pause()
                // Scrubbing keeps the bar visible; the hide timer
                // must not fire mid-drag.
                hideControlsTask?.cancel()
                controlsVisible = true
            } else if isCurrent {
                playCurrent()
                // Scrub ended: the bar stays a moment, then fades.
                showControlsTemporarily()
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
        newPlayer.isMuted = isMuted
        player = newPlayer
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isScrubbing, !restartFromStart else { return }
            currentTime = time.seconds
            let total = newPlayer.currentItem?.duration.seconds ?? 0
            if total.isFinite && total > 0 { duration = total }
            // Loop: TikTok replays the video when it ends. Done here
            // (not with a NotificationCenter observer) so nothing
            // leaks when the player is kept across swipes.
            if isPlaying, total > 0, time.seconds >= total - 0.25 {
                seek(to: 0)
            }
        }
    }

    /// Plays this page once its layer is attached. Starting playback
    /// the instant the player was created — before the PlayerView's
    /// AVPlayerLayer existed — is what left the next video with
    /// sound but no picture after a swipe: the player was already
    /// playing when its layer was created, and the layer never picked
    /// up the video track. So playback waits a beat (the layer is
    /// created by the state update in the meantime), then seeks to
    /// the current frame first, which forces the layer to render a
    /// fresh frame, and plays.
    private func schedulePlay() {
        if player == nil { setupPlayer() }
        guard player != nil else { return }
        playTask?.cancel()
        playTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            playCurrent()
        }
    }

    /// Seek to the current frame (restart from the top if the video
    /// already ended, or if this page just became current after a
    /// swipe — restartFromStart) and play at the chosen speed. The
    /// seek is what makes the layer render a frame instead of staying
    /// frozen/black.
    private func playCurrent() {
        guard let player, isCurrent else { return }
        let rate = playbackRate
        let target: CMTime
        if restartFromStart {
            target = .zero
            restartFromStart = false
        } else if duration > 0 && currentTime >= duration - 0.5 {
            target = .zero
        } else {
            target = player.currentTime()
        }
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            player?.rate = rate
        }
        isPlaying = true
    }

    /// Playback speed from the running-person button. Applies immediately
    /// when the video is playing; otherwise it applies on resume.
    private func selectRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    /// "…" menu "Save to Photos": download the video (or image)
    /// and save it to the Photos library, like TikTok's Download.
    private func downloadVideo() async {
        do {
            try await viewModel.saveToPhotos(item: item)
            showNotice("Đã lưu vào Photos")
        } catch {
            showNotice("Không lưu được")
        }
    }

    /// "…" menu "Share": download the video (or image) file, then
    /// open the iOS share sheet with it.
    private func shareItem() {
        Task {
            do {
                shareFile = ShareFile(url: try await viewModel.shareFileURL(for: item))
            } catch {
                showNotice("Không tải được file để chia sẻ")
            }
        }
    }

    /// Shows a short notice above the progress bar, then hides it.
    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            notice = nil
        }
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
            playCurrent()
            flashIcon("play.fill")
        }
    }

    /// Mute/unmute this page's player (speaker icon in the toolbar).
    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    /// One icon button in the Photos-style bottom toolbar: a blue
    /// 22pt icon, evenly spread (each button takes an equal share
    /// of the width).
    private func playerTabButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
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

    /// Facebook Reels-style progress bar auto-hide: shows the bar
    /// and fades it out after 2.5s with no interaction. Called on
    /// every interaction (tap, page appearing, scrub ending) — each
    /// call cancels the previous timer and starts a fresh one. Never
    /// hides while the user is scrubbing (the timer checks
    /// isScrubbing before hiding, and scrubbing cancels it).
    private func showControlsTemporarily() {
        controlsVisible = true
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            if !isScrubbing {
                withAnimation(.easeInOut(duration: 0.3)) {
                    controlsVisible = false
                }
            }
        }
    }

    /// Seek from a progress-bar scrub. Clears isScrubbing only in the
    /// seek's completion — AFTER the player is at the new position.
    /// The isScrubbing=false change triggers playCurrent, and if that
    /// runs before the seek lands it seeks the player back to the old
    /// position (the bar "jumps back" to where it was). Clearing it
    /// here makes playCurrent a no-op (the player is already at the
    /// new position) and the video resumes from the scrubbed spot.
    private func seekFromScrub(to seconds: Double) {
        guard let player else {
            isScrubbing = false
            return
        }
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            currentTime = seconds
            isScrubbing = false
        }
    }

    /// Photo posts: the thumbnail is the full-resolution image (the
    /// ingest saves one full frame, unscaled), so it is the image to show.
    private func loadFullImage() async {
        guard fullImage == nil, let api = viewModel.api else { return }
        fullImage = try? await api.fetchThumbnail(id: item.id)
    }
}


/// Photos-style info sheet for one item (the (i) button in the
/// Player toolbar): the media, caption, posted date, quality info,
/// and "Saved from <platform>" (tappable — opens the original post
/// in Safari). Save to Photos and Add to Album live here too, so
/// they are still reachable from the Player now that the top-right
/// "…" menu is gone.
private struct ItemInfoSheet: View {
    let item: Item
    var onSaveToPhotos: () -> Void = {}
    var onAddToAlbum: () -> Void = {}
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var thumb: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let thumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let caption = item.caption,
                       !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(caption)
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    // Date posted (or saved date when the post date
                    // is unknown): "Tuesday · 13 Oct 2026 · 18:13".
                    if let dateString = infoDateString {
                        Text(dateString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // Quality info: "720p · 1280 × 720 · 2.4 MB"
                    // plus the duration for videos.
                    if let quality = qualityString {
                        Text(quality)
                            .font(.subheadline)
                    }
                    if let duration = item.formattedDuration {
                        Text(duration)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // "Saved from <platform>" — tappable, opens the
                    // original post in Safari. Imported photos have
                    // no original post (album:// URL), so they show
                    // "Imported from Photos" instead.
                    if let originalURL = URL(string: item.originalUrl),
                       let scheme = originalURL.scheme, scheme.hasPrefix("http") {
                        Button {
                            dismiss()
                            UIApplication.shared.open(originalURL)
                        } label: {
                            HStack {
                                Text("Saved from \(item.platform.displayName)")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.blue)
                    } else {
                        Text("Imported from Photos")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Button {
                        dismiss()
                        onSaveToPhotos()
                    } label: {
                        Label("Save to Photos", systemImage: "arrow.down.to.line")
                    }
                    Button {
                        dismiss()
                        onAddToAlbum()
                    } label: {
                        Label("Add to Album", systemImage: "folder.badge.plus")
                    }
                }
                .padding()
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard thumb == nil, let api = viewModel.api else { return }
                thumb = try? await api.fetchThumbnail(id: item.id)
            }
        }
    }

    /// "Tuesday · 13 Oct 2026 · 18:13" — the posted date, or the
    /// saved date when the post date is unknown.
    private var infoDateString: String? {
        let date = item.postedDate ?? item.savedDate
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE · d MMM yyyy · HH:mm"
        return formatter.string(from: date)
    }

    /// "720p · 1280 × 720 · 2.4 MB" (video) or "1280 × 720 · 2.4 MB"
    /// (photo). The "720p" label comes from the smaller side, so a
    /// vertical 720×1280 video reads "720p" too.
    private var qualityString: String? {
        var parts: [String] = []
        if let width = item.width, let height = item.height {
            parts.append(qualityLabel(for: min(width, height)))
            parts.append("\(width) × \(height)")
        }
        if let size = item.formattedFileSize {
            parts.append(size)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func qualityLabel(for pixels: Int) -> String {
        switch pixels {
        case 2160...: return "2160p"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        case 480..<720: return "480p"
        default: return "\(pixels)p"
        }
    }
}

/// "Add to collection" picker: the user's collections plus a row to
/// create a new one. The list refreshes when it opens. Shared by the
/// feed and grid context menus ("Add to Album") — presented as its own
/// sheet from the menu. `onCancel` dismisses the sheet.
struct AddToCollectionPickerView: View {
    let item: Item
    /// Called after a successful add (collection name, newly added?).
    let onAddedToCollection: (String, Bool) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newCollectionName = ""
    @State private var pickerError: String?
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Text("Add to collection")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            if let pickerError {
                Text(pickerError)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(viewModel.myCollections) { collection in
                        Button {
                            Task { await addToCollection(collection) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.name)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("\(collection.count) video")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer()
                                if isAdding {
                                    ProgressView().tint(.white)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdding)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        TextField("Tên collection mới", text: $newCollectionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                        Button("Tạo") {
                            Task { await createAndAdd() }
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                .padding(.top, 8)
            }
        }        .task {
            await viewModel.fetchMyCollections()
        }
    }

    private func addToCollection(_ collection: MyCollection) async {
        guard !isAdding else { return }
        isAdding = true
        pickerError = nil
        defer { isAdding = false }
        if let added = await viewModel.addItemToMyCollection(collectionId: collection.id, item: item) {
            onAddedToCollection(collection.name, added)
            dismiss()
        } else {
            pickerError = "Không thêm được. Kiểm tra kết nối rồi thử lại."
        }
    }

    private func createAndAdd() async {
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isAdding else { return }
        isAdding = true
        pickerError = nil
        defer { isAdding = false }
        guard let created = await viewModel.createMyCollection(name: name) else {
            pickerError = "Không tạo được collection. Kiểm tra kết nối rồi thử lại."
            return
        }
        if let added = await viewModel.addItemToMyCollection(collectionId: created.id, item: item) {
            onAddedToCollection(created.name, added)
            dismiss()
        } else {
            pickerError = "Đã tạo \(created.name) nhưng chưa thêm được video."
        }
    }
}

/// Thin progress bar at the very bottom edge of a feed page (TikTok
/// style): a 2pt line — track white 30%, played portion white.
/// Dragging scrubs; while dragging, a preview popup (sprite frame at
/// that timestamp + time) floats above the bar. The touch area is
/// taller than the visible line so it is easy to grab.
/// Facebook Reels-style progress bar for the full-screen feed.
///
/// - Auto-hide: the bar is only visible while the user interacts.
///   It fades in on tap / page-appear / scrub and fades out after
///   2.5s idle (the timer lives in FeedVideoPage; this view only
///   reads `controlsVisible`). While scrubbing it is always visible.
/// - Enlarge on drag: the bar grows from a 2pt line to a 9pt pill
///   while the finger is down, and shrinks back on release.
/// - Seek preview: while scrubbing, a rounded thumbnail of the frame
///   at the scrub timestamp floats above the finger, with the time
///   ("0:12 / 0:36" — scrub time / total) in white below it. The
///   popup is lifted ~40pt above the bar so the finger never covers
///   the preview or the time. Even without a sprite (older saves)
///   the time still shows while scrubbing.
private struct FeedProgressBar: View {
    let currentTime: Double
    let duration: Double
    @Binding var isScrubbing: Bool
    /// False after 2.5s idle (FeedVideoPage's timer). The bar fades
    /// out, but the 64pt touch area stays live so the user can still
    /// grab it to scrub — and any tap on the video shows it again.
    let controlsVisible: Bool
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

    /// True while the bar should be on screen (interacting, or
    /// scrubbing — which forces it visible even after the idle
    /// timer fired).
    private var barVisible: Bool { controlsVisible || isScrubbing }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: isScrubbing ? 4.5 : 1)
                        .fill(Color.white.opacity(0.3))
                    RoundedRectangle(cornerRadius: isScrubbing ? 4.5 : 1)
                        .fill(Color.white)
                        .frame(width: geo.size.width * (isScrubbing ? scrubFraction : progress))
                }
                // Thin 2pt line at rest; grows to a 9pt pill while
                // scrubbing (Facebook Reels). Fades out after 2.5s
                // idle (barVisible), fades back in on interaction.
                .frame(height: isScrubbing ? 9 : 2)
                .animation(.easeInOut(duration: 0.2), value: isScrubbing)
                .opacity(barVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: barVisible)
            }
            // 64pt tall touch area (the visible line is only 2pt, at
            // the bottom): the bar is a thin line and the finger
            // often lands just above it, which the ScrollView then
            // took as a swipe — the bar "missed". The extra height
            // extends UPWARD only (the VStack's Spacer absorbs it),
            // so the username below does not move. Combined with the
            // high-priority gesture and scrollDisabled while
            // scrubbing, a touch starting anywhere near the bar
            // scrubs instead of paging.
            .frame(height: 64, alignment: .bottom)
            .contentShape(Rectangle())
            // High-priority: the feed is a vertical paging ScrollView
            // and it sometimes steals this drag (the bar "misses" the
            // scrub). A plain .gesture loses to the ScrollView when the
            // finger moves even slightly vertical; high-priority makes
            // a touch that starts on the bar always scrub. The bar is
            // only 64pt tall at the very bottom, so vertical swipes
            // starting elsewhere still page normally (same as TikTok).
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        scrubFraction = fraction
                        dragX = value.location.x
                        isScrubbing = true
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        // Do NOT clear isScrubbing here. The seek's
                        // completion clears it (see seekFromScrub):
                        // clearing it now fires playCurrent, which
                        // seeks back to the OLD position and overrides
                        // this seek — the bar "jumps back" to where it
                        // was. The seek must land first.
                        onSeek(fraction * duration)
                    }
            )
            .overlay(alignment: .bottomLeading) {
                if isScrubbing {
                    scrubPopup(in: geo.size.width)
                }
            }
        }
        // 64pt tall touch area (the visible line is only 2pt, at the
        // bottom) so the bar is easy to grab.
        .frame(height: 64)
    }

    /// Seek preview popup (Facebook Reels style): the sprite frame at
    /// the scrub timestamp, rounded with a soft shadow, with the time
    /// ("0:12 / 0:36" — scrub time / total duration) in white below
    /// it. Centred on the finger (clamped to the screen edges) and
    /// lifted ~40pt above the bar, so the finger never covers the
    /// preview or the time. Without a sprite the time still shows.
    private func scrubPopup(in width: CGFloat) -> some View {
        let frame = frameImage(for: scrubFraction * duration)
        let popupWidth: CGFloat = 120
        let aspect: CGFloat = frame.map { $0.size.width / max($0.size.height, 1) } ?? (9.0 / 16.0)
        // Cap the height so a tall portrait frame stays compact.
        let frameHeight = min(popupWidth / aspect, 180)
        let half = popupWidth / 2
        let centerX = min(max(dragX, half + 8), width - half - 8)
        return VStack(spacing: 8) {
            if let frame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .frame(width: popupWidth, height: frameHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
            }
            Text("\(formatTime(scrubFraction * duration)) / \(formatTime(duration))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
        }
        .offset(x: centerX - half, y: -40)
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

/// Enables the NATIVE interactive pop gesture (swipe from the left
/// edge) in the Player and the album details, alongside their
/// ScrollViews. No custom DragGesture is used anywhere — the back
/// swipe is the system's own interactive pop.
///
/// Two things block the native pop, and this fixes both:
/// 1. The ScrollView claims the touch, so the navigation
///    controller's edge pan never fires. Fix (UIKit, the standard
///    pattern for ScrollView + pop): make the scroll view's pan
///    gesture wait — it only recognizes if the edge pan fails.
///    A rightward pan from the left edge then pops natively; a
///    vertical pan fails the edge pan immediately, so the feed
///    still pages (Player) and the grid still scrolls (album).
///    This also makes the album pop SMOOTHER: the grid's pan no
///    longer competes with the edge pan, so the pop starts at
///    once instead of hesitating while the system decides.
/// 2. The pop gesture's delegate can veto the pop when the nav
///    bar is hidden (the Player hides it for fullscreen). Fix: a
///    small delegate that allows the pop whenever there is a view
///    to pop to (viewControllers.count > 1). It does not touch the
///    interactive transition itself, only whether the gesture may
///    begin — so the animation stays the system's.
///
/// This is a UIViewControllerRepresentable so the wiring runs in
/// `viewDidAppear` — after layout, when the ScrollView definitely
/// exists. The v45 plain-UIView version wired up in `updateUIView`,
/// which could run before the ScrollView was created, so the pop
/// never got enabled (that is why the Player gesture did not work
/// in v45). It retries once shortly after, in case the ScrollView
/// is created late (e.g. items loaded async). Wiring is scoped to
/// the hosting view controller's view, so other tabs' scroll views
/// are untouched.
struct NativePopGestureHelper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        NativePopGestureViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// A hidden helper view controller whose only job is to wire the
/// native pop gesture. Its view is empty and invisible.
private final class NativePopGestureViewController: UIViewController {
    /// Retained: UIGestureRecognizer.delegate is weak, so the
    /// delegate object must be held or it deallocates at once.
    private var popDelegate: PopGestureDelegate?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        wireUp()
        // Retry once shortly after, in case the ScrollView was
        // created after the first pass (e.g. items loaded async).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.wireUp()
        }
    }

    private func wireUp() {
        guard let nav = navigationController,
              let pop = nav.interactivePopGestureRecognizer else { return }
        // Force the pop gesture on (a hidden nav bar can disable it).
        pop.isEnabled = true
        // Install (or RE-install) a delegate that allows the pop
        // whenever there is a view to pop to, overriding any veto
        // from the hidden nav bar. The transition animation itself
        // is untouched — only whether the gesture may begin.
        //
        // The delegate must be re-installed, not just "installed
        // once": pop.delegate is weak, so when a pushed screen is
        // popped its helper (and its delegate) deallocates and
        // pop.delegate becomes nil — and another screen's helper may
        // have replaced ours in the meantime. If this helper only
        // installs when ITS OWN popDelegate is nil, it never restores
        // the gesture after returning from that screen. (Bug: after
        // viewing a video and popping back to the album, swipe-back
        // to Albums stopped working — the Player's delegate had
        // deallocated and the album's helper never reinstalled its
        // own.) So always ensure OUR delegate is the current one.
        if popDelegate == nil {
            let delegate = PopGestureDelegate()
            delegate.navigationController = nav
            popDelegate = delegate
        }
        if pop.delegate !== popDelegate {
            pop.delegate = popDelegate
        }
        // The hosting (SwiftUI) view controller's view holds the
        // ScrollView — the paging feed (Player) or the grid
        // (album). Make its pan wait for the pop gesture.
        guard let hostView = parent?.view else { return }
        for scrollView in Self.scrollViews(in: hostView) {
            scrollView.panGestureRecognizer.require(toFail: pop)
        }
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView {
                found.append(scrollView)
            }
            found.append(contentsOf: scrollViews(in: subview))
        }
        return found
    }
}

/// Delegate for the navigation controller's interactive pop gesture.
/// Allows the pop whenever there is a view to pop to, and lets the
/// scroll view's pan coexist (require(toFail:) orders them, so the
/// edge pan wins when it starts at the edge).
private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navigationController: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController else { return false }
        return nav.viewControllers.count > 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
