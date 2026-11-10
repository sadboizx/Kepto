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
/// There is NO "..." button on the video: all video actions live in
/// the long-press menu (Copy link, Download, Playback speed, Add to
/// collection, Delete) plus the video's username + caption. No
/// Share-with / Repost / friends list.
struct FeedView: View {
    /// The list to page through. A Binding so appends from `onNearEnd`
    /// (the library's loadMore, or a collection's) are visible here.
    @Binding var items: [Item]
    /// The item the feed opens on.
    let startItemId: String
    /// Called when the user nears the end (loads the next page).
    var onNearEnd: (() async -> Void)? = nil

    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    /// The id of the page the feed is showing. Optional because
    /// `.scrollPosition(id:)` needs a `Binding<String?>`.
    @State private var currentItemId: String?
    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?
    /// The video a long-press Delete is about to delete (captured when
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
            // Back swipe to go back (there is no X button): a
            // deliberate rightward swipe on the video dismisses the
            // player. Simultaneous, so it never blocks the vertical
            // paging or the progress-bar scrub. Drags that start
            // near the bottom (the progress bar / caption area) are
            // ignored, so scrubbing cannot dismiss the player.
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        let isSwipeRight = value.translation.width > 120
                            && abs(value.translation.height) < 60
                        let startedAboveBottomBar = value.startLocation.y < geo.size.height - 180
                        if isSwipeRight && startedAboveBottomBar {
                            dismiss()
                        }
                    }
            )
        }
        .preferredColorScheme(.dark)
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
/// the current one, and loops. Long-press opens the native iOS
/// context menu (Save to Photos, Share, Favorite, Playback speed,
/// Add to Album, Delete). The username and caption are overlaid on
/// the video itself, not repeated in the menu.
private struct FeedVideoPage: View {
    let item: Item
    let isCurrent: Bool
    /// Called when the user taps Delete in the context menu (the
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
    /// Playback speed from the context menu (1.0 = normal).
    @State private var playbackRate: Float = 1.0
    /// Speeds offered by the context menu's Playback speed submenu.
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    /// The context menu's "Add to Album" picker (nil = closed).
    @State private var showingAlbumPicker = false
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// Set when this page becomes current after a swipe: the next
    /// playCurrent starts from 0 (TikTok restarts the video every time
    /// you land on it) instead of resuming where the kept player left
    /// off. Cleared by playCurrent once it seeks to 0.
    @State private var restartFromStart = false
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
                // Bottom gradient so the username/caption stay legible
                // over the video (TikTok-style).
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
                // bar. There is no "…" button on the video any more,
                // so nothing covers this text.
                // Progress bar sits ABOVE the username (not at the
                // very bottom): the username is at the bottom edge,
                // just above the Home Indicator, and the progress bar
                // is right above it.
                VStack(spacing: 0) {
                    Spacer()
                    if item.status == .ready, !isImage {
                        FeedProgressBar(
                            currentTime: currentTime,
                            duration: duration,
                            isScrubbing: $isScrubbing,
                            item: item,
                            sprite: sprite,
                            frameCache: frameCache,
                            onSeek: { seconds in seekFromScrub(to: seconds) }
                        )
                        // 10pt above the username.
                        .padding(.bottom, 10)
                    }
                    if item.status == .ready {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.collectionName)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let caption = item.caption,
                               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(caption)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        // At the very bottom, just above the Home
                        // Indicator (a small gap, not touching it).
                        .padding(.bottom, geo.safeAreaInsets.bottom + 8)
                    }
                }
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
            }
            .contextMenu {
                // Native iOS context menu (long-press on the video):
                // Save to Photos, Share, Favorite, Playback speed
                // (submenu), Add to Album, Delete — same dark, large
                // radius, right-side icons, red Delete as the grid
                // menu. The video keeps playing while the menu is up
                // (native context-menu behaviour); the old bottom
                // sheet paused it, this one does not.
                if item.status == .ready {
                    Button { Task { await downloadVideo() } } label: {
                        Label("Save to Photos", systemImage: "arrow.down.to.line")
                    }
                    Button { shareItem() } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        Task {
                            if let updated = await viewModel.toggleFavorite(item: item) {
                                showNotice(updated.isFavorite ? "Đã thêm vào Favorite" : "Đã bỏ Favorite")
                            }
                        }
                    } label: {
                        Label("Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart")
                    }
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
                        Label("Playback speed", systemImage: "gauge")
                    }
                    Button { showingAlbumPicker = true } label: {
                        Label("Add to Album", systemImage: "folder.badge.plus")
                    }
                    Button(role: .destructive) {
                        onDeleteRequest?(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
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
            } else {
                playTask?.cancel()
                player?.pause()
                isPlaying = false
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                player?.pause()
            } else if isCurrent {
                playCurrent()
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

    /// Playback speed from the context menu. Applies immediately
    /// when the video is playing; otherwise it applies on resume.
    private func selectRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    /// Context menu "Save to Photos": download the video (or image)
    /// and save it to the Photos library, like TikTok's Download.
    private func downloadVideo() async {
        do {
            try await viewModel.saveToPhotos(item: item)
            showNotice("Đã lưu vào Photos")
        } catch {
            showNotice("Không lưu được")
        }
    }

    /// Context menu "Share": download the video (or image) file, then
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
                if isScrubbing, let frame = frameImage(for: scrubFraction * duration) {
                    scrubPopup(frame: frame, in: geo.size.width)
                }
            }
        }
        // 64pt tall touch area (the visible line is only 2pt, at the
        // bottom) so the bar is easy to grab.
        .frame(height: 64)
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
