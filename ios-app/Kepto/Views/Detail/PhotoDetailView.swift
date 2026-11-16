import AVFoundation
import SwiftUI
import UIKit

/// Photos-style full-screen viewer — replaces the TikTok-style FeedView
/// (Q1, step 7). Horizontal paging between items (Photos), pinch zoom
/// 1–5x for photos, video via the existing AVURLAsset + Bearer-header
/// pattern, swipe-up to open the Info sheet, Photos-style bottom
/// toolbar (Share / Favorite / Play-Pause / Mute / Speed / Info /
/// Delete, full-width blurred, as in v59–v60).
///
/// Differences from Photos' `PhotoDetailView` (deliberate, Kepto data):
/// no Live Photo (Kepto items have none), no Editor button (Q2: Editor
/// dropped), no Hide / Slideshow / Duplicate in the menu (Q3/Q4
/// dropped), no `ViewerRoute` — the viewer takes the same
/// `items: Binding` + `startItemId` + `onNearEnd` shape FeedView had,
/// so grid load-more appends and delete removals stay live. Videos
/// auto-play when the viewer opens on one and when paging onto one
/// (user decision, round 3 — the open auto-play question is now YES);
/// the centre play button shows only while paused; the player
/// machinery (deferred play, kept player, loop, scrub) is FeedView's,
/// reused as-is.
/// The viewer is presented as a full-screen OVERLAY over the grid
/// that opened it (not a NavigationStack push): the grid stays in
/// the same view hierarchy underneath, so it genuinely shows through
/// when the black background fades during a drag-down-to-dismiss —
/// a push cannot do that (the pushed view's hosting layer is opaque,
/// so fading the black layers only ever revealed black, and the
/// standard pop slid a black bar across the screen). Closing the
/// viewer just removes the overlay (no pop animation, no slide).
/// There is NO swipe-back here (user request): the
/// drag-down-to-dismiss is the viewer's only exit — a custom
/// gesture, added at the user's explicit request (Photos-style: only
/// the media moves and shrinks, the background + chrome fade).
/// The status bar is hidden while the viewer is open, and the app
/// tab bar cross-fades with the viewer toolbar during a dismiss
/// drag (TabBarFadeHelper fades the real UITabBar with the same
/// drag progress — no fake tab bar, no binary show/hide snap).
/// The viewer toolbar is 78pt tall, like Apple Photos (measured).
/// `NativePopGestureHelper` (same v46 bridge) still lives in this
/// file for the album detail views.
struct PhotoDetailView: View {
    /// The list to page through. A Binding so appends from `onNearEnd`
    /// (the library's loadMore, or a collection's) are visible here.
    @Binding var items: [Item]
    /// The item the viewer opens on.
    let startItemId: String
    /// Called when the user nears the end (loads the next page).
    var onNearEnd: (() async -> Void)? = nil
    /// Retained for the existing call sites (Library / Search /
    /// For You / albums pass a title); no longer displayed — the top
    /// bar shows only the centred date now.
    var title: String = L10n.library
    /// Close the viewer (the opener clears its `feedStartItem`, which
    /// removes this overlay). The drag-down release and the
    /// delete-the-last-item path both go through here — there is no
    /// NavigationStack pop any more (see the header comment).
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject private var viewModel: LibraryViewModel

    /// The id of the page the viewer is showing. Optional because
    /// `.scrollPosition(id:)` needs a `Binding<String?>`.
    @State private var currentID: String?
    @State private var chrome = true
    @State private var zoomed = false
    @State private var showDelete = false
    @State private var deleteError: String?
    /// The video a Delete is about to delete (captured when the user
    /// taps Delete, so a swipe in between cannot retarget it).
    @State private var itemPendingDelete: Item?
    /// True while the user is dragging a page's progress bar. The
    /// paging ScrollView is disabled while this is true, so a scrub
    /// drag that drifts slightly horizontal cannot be stolen mid-drag
    /// and turn into a page swipe. Lifted here from the page because
    /// the ScrollView lives in this view.
    @State private var isScrubbing = false
    /// Drag-down-to-dismiss state (Photos viewer): the current
    /// page's media follows the finger down and shrinks; the black
    /// background and the chrome fade with the drag so the album grid
    /// behind shows through. Owned here (not in the page) so the
    /// background + chrome — which live outside the page — and the
    /// page's media move from the same values.
    /// `dragOffset` is the media's live offset (x stays 0 while
    /// dragging; on a dismissing release it animates to the source
    /// thumbnail's centre), `dragScale` its live scale (1 → ~0.65 at
    /// full drag; on release it animates to the thumbnail's scale),
    /// `dismissing` is true once the release-dismiss animation has
    /// started (background + chrome animate to fully transparent).
    @State private var dragOffset: CGSize = .zero
    @State private var dragScale: CGFloat = 1
    @State private var dismissing = false
    /// The global frame of the thumbnail the viewer opened from (nil
    /// when opened from Search / For You, or when the cell scrolled
    /// away): on a dismissing release the media shrinks onto it.
    var sourceFrame: CGRect? = nil

    init(items: Binding<[Item]>, startItemId: String,
         onNearEnd: (() async -> Void)? = nil, title: String = L10n.library,
         sourceFrame: CGRect? = nil, onDismiss: (() -> Void)? = nil) {
        self._items = items
        self.startItemId = startItemId
        self.onNearEnd = onNearEnd
        self.title = title
        self.sourceFrame = sourceFrame
        self.onDismiss = onDismiss
        self._currentID = State(initialValue: startItemId)
    }

    private var currentIndex: Int? { items.firstIndex { $0.id == currentID } }
    private var currentItem: Item? { currentIndex.flatMap { items[$0] } }

    /// How far the drag has faded the viewer: 0 at rest, 1 at ~300pt
    /// down (the background is fully transparent and the grid behind
    /// is fully visible).
    private var dragProgress: CGFloat {
        min(max(dragOffset.height, 0) / 300, 1)
    }
    /// The viewer's black background opacity: fades with the drag,
    /// and to 0 once the release-dismiss starts (the grid behind
    /// takes over).
    private var backgroundOpacity: CGFloat {
        dismissing ? 0 : (1 - dragProgress)
    }
    /// The chrome (top bar + the page's toolbar / progress bar)
    /// fades with the drag, in place — it never moves.
    private var chromeOpacity: CGFloat {
        dismissing ? 0 : (1 - dragProgress)
    }
    /// The app tab bar's opacity during a dismiss drag: 0 while the
    /// viewer is open and idle (the viewer covers it), fading to 1
    /// with the drag so it cross-fades against the viewer toolbar
    /// (Photos). 1 while a release-dismiss is running (the grid is
    /// taking over). Driven by the SAME dragProgress the chrome and
    /// background use, so the two bars move in sync. The real
    /// UITabBar is faded by TabBarFadeHelper (below); the tab bar
    /// is never interactive while the viewer is open (the helper
    /// keeps hit-testing off and restores it when the viewer goes
    /// away).
    private var tabBarAlpha: CGFloat {
        dismissing ? 1 : dragProgress
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // Fades with the drag-down-to-dismiss (and to 0 on a
                // dismissing release): the album grid behind the
                // pushed viewer shows through as it fades.
                Color.black.ignoresSafeArea()
                    .opacity(backgroundOpacity)
                if items.isEmpty {
                    emptyState
                } else {
                    pager
                }
                // Top bar only — the bottom toolbar lives in the page
                // (it needs the page's player state: play/pause, mute,
                // speed). Both hide together with `chrome`. The bar
                // stays in place during a dismiss drag and fades.
                if chrome {
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                    }
                    .opacity(chromeOpacity)
                    .transition(.opacity)
                }
            }
            // No swipe-back here (user request): the drag-down-to-
            // dismiss in the page is the viewer's only exit. The
            // paging ScrollView claims touches; horizontal swipes
            // still page the viewer.
        }
        // No taps while the release-dismiss animation is running
        // (the viewer is closing anyway).
        .disabled(dismissing)
        // Full-screen viewer: hide the navigation bar (no back
        // button/title — the custom topBar provides them) and the
        // status bar (no clock/battery over the media while viewing;
        // it returns when the viewer closes — the modifier leaves
        // with the overlay). The tab bar is always rendered while
        // the viewer is open — TabBarFadeHelper (below) fades the
        // real UITabBar in with the drag (alpha 0 at rest, so it is
        // invisible and non-interactive while viewing, and it
        // cross-fades against the viewer toolbar during a dismiss
        // drag, like Photos). No binary .toolbar(.hidden/.visible)
        // toggle here — that snapped instead of fading.
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .background(TabBarFadeHelper(alpha: tabBarAlpha))
        .confirmationDialog(L10n.deleteSavedItemsTitle(1),
                            isPresented: $showDelete,
                            titleVisibility: .visible) {
            Button(L10n.delete, role: .destructive) {
                Task { await deleteCurrentItem() }
            }
            Button(L10n.cancel, role: .cancel) { itemPendingDelete = nil }
        } message: {
            Text(L10n.deleteSingleFromCloudMessage)
        }
        .alert(L10n.deleteFailed, isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .animation(.easeInOut(duration: 0.2), value: chrome)
    }

    /// Empty state when there is nothing to page through.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.nothingHere, systemImage: "tray")
        } description: {
            Text(L10n.noVideosToShow)
        }
    }

    /// The paging scroll view: one full-screen page per item.
    private var pager: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        pageView(for: item)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            // Paging pauses while a photo is zoomed (Photos), while
            // a progress-bar scrub is in progress, or while a
            // dismiss drag is moving the media down (the page must
            // not shift sideways mid-drag).
            .scrollDisabled(zoomed || isScrubbing || dragOffset.height > 0)
            .ignoresSafeArea()
            .onChange(of: currentID) { _, _ in handleCurrentItemChange() }
            .onChange(of: items) { oldItems, newItems in handleItemsChange(old: oldItems, new: newItems) }
            .task { fixInitialCurrentItem() }
            .task { await scrollToStartItem(proxy: proxy) }
        }
    }

    /// One page of the pager: the PhotoDetailPage for one item with
    /// all its bindings. A separate function so the ScrollViewReader
    /// closure in `pager` stays small enough for the compiler to
    /// type-check in reasonable time.
    private func pageView(for item: Item) -> some View {
        PhotoDetailPage(
            item: item,
            isCurrent: item.id == currentID,
            items: $items,
            chromeVisible: $chrome,
            zoomed: $zoomed,
            onDeleteRequest: { video in
                itemPendingDelete = video
                showDelete = true
            },
            onDismiss: onDismiss,
            isScrubbing: $isScrubbing,
            dragOffset: $dragOffset,
            dragScale: $dragScale,
            dismissing: $dismissing,
            chromeOpacity: chromeOpacity,
            backgroundOpacity: backgroundOpacity,
            sourceFrame: sourceFrame
        )
        .id(item.id)
        .containerRelativeFrame(.horizontal)
    }

    /// Top bar (Photos): the current item's date centred, no back
    /// button / title and no Edit button (Q2: Editor dropped; the
    /// "< album" back label was removed at the user's request —
    /// drag-down-to-dismiss is the viewer's only exit). White text
    /// over a top gradient, like Photos.
    private var topBar: some View {
        ZStack {
            // Centred date (posted, else saved).
            VStack(spacing: 1) {
                if let date = currentItem?.postedDate ?? currentItem?.savedDate {
                    Text(DateLabels.dayTitle(for: date))
                        .font(.subheadline.weight(.semibold))
                    Text(DateLabels.timeString(for: date))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    /// The viewer must open on the item the user tapped, not the first
    /// one. `.scrollPosition` does not always apply its initial value
    /// on first layout (the target page may not be laid out yet in the
    /// LazyHStack), so scroll to the start item explicitly once the
    /// layout settles.
    private func scrollToStartItem(proxy: ScrollViewProxy) async {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        if items.contains(where: { $0.id == startItemId }) {
            proxy.scrollTo(startItemId, anchor: .leading)
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
    /// remaining item instead of a blank page.
    private func handleItemsChange(old oldItems: [Item], new newItems: [Item]) {
        guard !newItems.contains(where: { $0.id == currentID }) else { return }
        if let oldIdx = oldItems.firstIndex(where: { $0.id == currentID }) {
            let nextIdx = min(oldIdx, newItems.count - 1)
            if nextIdx >= 0 { currentID = newItems[nextIdx].id }
        } else if let last = newItems.last {
            currentID = last.id
        }
    }

    /// If the viewer opened on an id that is not in the list, start at
    /// the first item.
    private func fixInitialCurrentItem() {
        if !items.contains(where: { $0.id == currentID }),
           let first = items.first {
            currentID = first.id
        }
    }

    private func deleteCurrentItem() async {
        guard let target = itemPendingDelete ?? currentItem else { return }
        itemPendingDelete = nil
        do {
            try await viewModel.delete(item: target)
            // Also drop it from this viewer's list: when the viewer was
            // opened from a collection, the view model's list is a
            // different array, so the deleted page would otherwise stay
            // on screen. Removing it here moves the viewer to the
            // nearest remaining item (see `handleItemsChange`).
            items.removeAll { $0.id == target.id }
            if items.isEmpty { onDismiss?() }
        } catch {
            deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// One full-screen page in the viewer: the photo (pinch zoom 1–5x,
/// double-tap 1 <-> 2.6x) or the video (full-bleed, auto-plays on
/// open / paging onto it — round 3; pause with the centre button or
/// the toolbar Pause button), the progress bar with scrub + sprite
/// preview, and the Photos-style bottom toolbar. Adapted from
/// FeedView's `FeedVideoPage`: the player machinery (deferred play,
/// kept player, loop, scrub, mute, speed, share, save) is reused
/// as-is; the TikTok parts are gone (vertical paging, auto-play on
/// swipe, restart-from-start, username/caption overlay, top-right
/// "…" menu). Single tap toggles the chrome (top bar + toolbar +
/// progress bar); swipe up opens the Info sheet.
private struct PhotoDetailPage: View {
    let item: Item
    let isCurrent: Bool
    /// The list the viewer pages through (for the Favorite button to
    /// refresh the item in place — the page's `item` is a snapshot).
    @Binding var items: [Item]
    @Binding var chromeVisible: Bool
    @Binding var zoomed: Bool
    /// Called when the user taps Delete in the toolbar (the viewer
    /// shows the delete confirmation for this item).
    var onDeleteRequest: ((Item) -> Void)? = nil
    /// Close the viewer (the opener removes the overlay). The
    /// drag-down release calls this after the media has landed on
    /// its thumbnail — there is no NavigationStack pop any more.
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject private var viewModel: LibraryViewModel

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    /// Bound to the viewer: true while the user drags this page's
    /// progress bar. The viewer disables the paging ScrollView while
    /// it is true, so a scrub cannot be stolen mid-drag.
    @Binding var isScrubbing: Bool
    /// Drag-down-to-dismiss state, owned by the viewer (shared with
    /// the background + chrome): the media's live offset/scale, and
    /// whether the release-dismiss animation is running. Only the
    /// current page writes these (the gesture is gated on
    /// `isCurrent`).
    @Binding var dragOffset: CGSize
    @Binding var dragScale: CGFloat
    @Binding var dismissing: Bool
    /// Background + chrome opacity for this page, from the viewer's
    /// drag progress (1 = opaque at rest, fading as the media is
    /// dragged down, 0 once the release-dismiss starts).
    var chromeOpacity: CGFloat = 1
    var backgroundOpacity: CGFloat = 1
    /// The global frame of the thumbnail the viewer opened from (nil
    /// when opened from Search / For You, or when the cell scrolled
    /// away): on a dismissing release the media shrinks onto it.
    var sourceFrame: CGRect? = nil
    /// Whether the video was playing when a scrub started — it resumes
    /// after the scrub only in that case (a paused video stays paused).
    @State private var wasPlayingBeforeScrub = false
    @State private var sprite: UIImage?
    @StateObject private var frameCache = ScrubPreviewPlayer.SpriteFrameCache()
    @State private var timeObserver: Any?
    @State private var fullImage: UIImage?
    /// Playback speed from the running-person button (1.0 = normal).
    @State private var playbackRate: Float = 1.0
    /// Whether the speed picker popover is open (the running-person
    /// button). A Button + popover, NOT a Menu: a Menu's dismissal
    /// tap passed through to this page's full-screen chrome-toggle
    /// tap gesture and hid the chrome (frames h_08/h_09, round 3) —
    /// a Button consumes its own tap and a popover consumes outside
    /// taps, so neither can reach the toggle.
    @State private var showingSpeedPicker = false
    /// Speeds offered by the running-person button's menu.
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    /// Mute state for this page's player (speaker icon in the
    /// toolbar). Per-page — a new video starts with sound.
    @State private var isMuted = false
    /// The Photos-style info sheet (the (i) button in the toolbar).
    @State private var showingInfo = false
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// Progress bar visibility (Photos): the bar stays visible
    /// whenever the chrome is shown — it never fades out on its own.
    /// Starts visible when the page becomes current.
    @State private var controlsVisible: Bool = true
    /// Short notice above the progress bar (e.g. "Đã lưu vào Photos").
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    /// Pinch zoom for photos (Photos: 1–5x).
    @State private var scale: CGFloat = 1
    @GestureState private var magnify: CGFloat = 1

    private var isImage: Bool { item.contentType?.hasPrefix("image/") == true }

    /// The photo / video (or its loading / error state) — the ONLY
    /// part that moves during a dismiss drag. The centre play button,
    /// the bottom gradient, the toolbar and the notice are siblings
    /// of this, so they stay in place and fade instead.
    private var mediaContent: some View {
        Group {
            if item.status == .ready, !isImage {
                if let player {
                    // Full-bleed (Photos): the video fills the
                    // frame edge to edge, under the status bar and
                    // to the bottom edge — the sides crop slightly
                    // instead of letterboxing.
                    PlayerView(player: player, videoGravity: .resizeAspectFill)
                } else {
                    ProgressView().tint(.white)
                }
            } else if item.status == .ready, isImage {
                if let fullImage {
                    Image(uiImage: fullImage)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(max(scale, 1) * magnify)
                        .gesture(magnification)
                        .onTapGesture(count: 2, perform: doubleTap)
                } else {
                    ProgressView().tint(.white)
                }
            } else if item.status == .pending {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(L10n.processing)
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
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Fades with the dismiss drag (see the viewer): the
                // album grid behind the pushed viewer shows through
                // as it fades.
                Color.black
                    .opacity(backgroundOpacity)
                // The media ONLY — the centre play button, the bottom
                // gradient, the toolbar and the notice stay in place
                // and fade instead of moving. Scale BEFORE offset:
                // scaling first keeps the offset unscaled, so the
                // media's centre lands exactly on the thumbnail.
                mediaContent
                    .scaleEffect(dragScale)
                    .offset(dragOffset)
                // Centre play button for paused videos (Photos) —
                // the ONLY centre pause/play indicator. (The old
                // tap-flash icon that showed a second one is gone.)
                // Fades with the dismiss drag, in place.
                if item.status == .ready, !isImage, !isPlaying, player != nil {
                    Button {
                        togglePlay()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .padding(18)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(L10n.play)
                    .opacity(chromeOpacity)
                }
                // Bottom gradient so the toolbar icons stay legible
                // over the media (Photos-style). Fades with the
                // dismiss drag, in place.
                if item.status == .ready, chromeVisible {
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 180)
                    }
                    .opacity(chromeOpacity)
                }
                // Progress bar + Photos-style bottom toolbar. The
                // toolbar sits at the very bottom, just above the
                // Home Indicator, and the progress bar is right above
                // it. Both hide with the chrome — and fade, in place,
                // with the dismiss drag.
                VStack(spacing: 0) {
                    Spacer()
                    if item.status == .ready, !isImage {
                        FeedProgressBar(
                            currentTime: currentTime,
                            duration: duration,
                            isScrubbing: $isScrubbing,
                            controlsVisible: controlsVisible && chromeVisible,
                            item: item,
                            sprite: sprite,
                            frameCache: frameCache,
                            onSeek: { seconds in seekFromScrub(to: seconds) }
                        )
                        // 10pt above the toolbar.
                        .padding(.bottom, 10)
                    }
                    if item.status == .ready, chromeVisible {
                        // Photos toolbar: Share, Favorite, then (video
                        // only) Play/Pause, Mute, Speed, then Info,
                        // Delete. Photo: Share, Favorite, Info,
                        // Delete. Blue icons, evenly spread.
                        HStack(spacing: 0) {
                            playerTabButton(systemName: "square.and.arrow.up", label: L10n.share) {
                                shareItem()
                            }
                            playerTabButton(systemName: item.isFavorite ? "heart.fill" : "heart", label: item.isFavorite ? L10n.unfavorite : L10n.favorite) {
                                Task {
                                    if let updated = await viewModel.toggleFavorite(item: item) {
                                        // The page's `item` is a snapshot:
                                        // refresh the local list too so the
                                        // heart updates when the viewer was
                                        // opened from a collection/search.
                                        if let idx = items.firstIndex(where: { $0.id == item.id }) {
                                            items[idx] = updated
                                        }
                                        showNotice(updated.isFavorite ? "Đã thêm vào Favorite" : "Đã bỏ Favorite")
                                    }
                                }
                            }
                            if !isImage {
                                playerTabButton(systemName: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? L10n.pause : L10n.play) {
                                    togglePlay()
                                }
                                playerTabButton(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: isMuted ? L10n.unmute : L10n.mute) {
                                    toggleMute()
                                }
                                // Playback speed (running-person
                                // icon): a Button + popover, NOT a
                                // Menu — a Menu's dismissal tap hid
                                // the chrome (see showingSpeedPicker).
                                Button {
                                    showingSpeedPicker = true
                                } label: {
                                    Image(systemName: "figure.run")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.blue)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 50)
                                        .accessibilityLabel(L10n.playbackSpeed)
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showingSpeedPicker) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(speeds, id: \.self) { rate in
                                            Button {
                                                selectRate(rate)
                                                showingSpeedPicker = false
                                            } label: {
                                                HStack {
                                                    Text(String(format: "%gx", rate))
                                                    Spacer()
                                                    if rate == playbackRate {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .presentationCompactAdaptation(.popover)
                                }
                            }
                            playerTabButton(systemName: showingInfo ? "info.circle.fill" : "info.circle", label: L10n.info) {
                                showingInfo = true
                            }
                            playerTabButton(systemName: "trash", label: L10n.delete) {
                                onDeleteRequest?(item)
                            }
                        }
                        // Full-width with a blurred background, like
                        // the Photos toolbar (no horizontal inset —
                        // it spans edge to edge, and the blur extends
                        // to the bottom edge under the Home Indicator).
                        // Same height as Apple Photos, measured:
                        // Photos' toolbar is 78pt total (44pt bar +
                        // 34pt safe area; f_05 frame: icons 56pt
                        // above the bottom edge). Kepto was 66pt
                        // (50pt buttons + 8pt vertical padding)
                        // because geo.safeAreaInsets.bottom is 0 here
                        // — the pager ignores the safe area — so the
                        // old bottom padding added nothing. Now: 50pt
                        // buttons + 28pt bottom padding = 78pt total,
                        // icons 53pt above the bottom edge (≈ Photos'
                        // 56pt).
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 28)
                        .background(.ultraThinMaterial)
                    }
                }
                .opacity(chromeOpacity)
                .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                // Transient notice (e.g. "Đã lưu vào Photos"). Sits
                // above the progress bar so it never covers it.
                // Fades with the dismiss drag, like the rest of the
                // chrome.
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
                    .opacity(chromeOpacity)
                }
            }
            .contentShape(Rectangle())
            // Single tap toggles the chrome (Photos). Play/pause is
            // the centre button / toolbar button, not the tap.
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                showControlsTemporarily()
            }
            .simultaneousGesture(swipeUp)
            // Drag down to dismiss (Photos viewer): moves only the
            // media (see `dismissDrag` below). Simultaneous so the
            // tap, the swipe-up and the paging ScrollView keep
            // working alongside it.
            .simultaneousGesture(dismissDrag(pageSize: geo.size, pageGlobalFrame: geo.frame(in: .global)))
        }
        // Fades with the dismiss drag, like the black inside the
        // ZStack above — either one left opaque would hide the grid.
        .background(Color.black.opacity(backgroundOpacity))
        // Photos-style info sheet (the (i) button in the toolbar).
        // No Save to Photos / Add to Album here any more (user
        // request) — the sheet is info only.
        .sheet(isPresented: $showingInfo) {
            PhotoInfoView(item: item)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(activityItems: [file.url])
        }
        .onAppear {
            setupPlayer()
            if isCurrent {
                showControlsTemporarily()
                playIfVideo()
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
            player?.pause()
            isPlaying = false
            // A zoomed photo resets when the page scrolls away.
            scale = 1
            if zoomed { zoomed = false }
        }
        .onChange(of: isCurrent) { _, current in
            if current {
                // Swipe landed on this page: show the progress bar
                // and auto-play if it is a video (round 3).
                showControlsTemporarily()
                playIfVideo()
            } else {
                player?.pause()
                isPlaying = false
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                wasPlayingBeforeScrub = isPlaying
                player?.pause()
                // Scrubbing keeps the bar visible.
                controlsVisible = true
            } else if isCurrent {
                // Scrub ended: resume only if it was playing before
                // the scrub; the bar stays visible (Photos).
                if wasPlayingBeforeScrub { playCurrent() }
                showControlsTemporarily()
            }
        }
    }

    // MARK: - Zoom + swipe-up (Photos)

    private var magnification: some Gesture {
        MagnificationGesture()
            .updating($magnify) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale = min(max(scale * value, 1), 5)
                zoomed = scale > 1.02
            }
    }

    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.height < -70, abs(value.translation.width) < 90 {
                    showingInfo = true
                    Haptics.tap()
                }
            }
    }

    // MARK: - Drag down to dismiss (Photos viewer)

    /// A predominantly vertical downward drag on the media moves
    /// ONLY the media down with the finger and shrinks it; the black
    /// background and the chrome fade so the album grid behind shows
    /// through. The drag state lives in the viewer (`dragOffset` /
    /// `dragScale` / `dismissing` bindings) so the background and
    /// chrome move from the same values. The transform is a pure
    /// function of the live gesture value — no animation on
    /// `.onChanged` — so the media follows the finger with no jumps.
    ///
    /// Gated off while zoomed, while scrubbing, while a pinch is in
    /// progress, and for drags that start on the bottom chrome
    /// (progress bar / toolbar). Upward drags are not claimed here —
    /// the swipe-up above opens the info sheet. Horizontal paging is
    /// unaffected: the gesture is simultaneous, it ignores
    /// predominantly-horizontal drags, and the viewer disables the
    /// paging ScrollView once the drag has claimed the touch.
    /// `pageSize` / `pageGlobalFrame` are plain values captured at
    /// body-evaluation time (the page does not move or resize during
    /// a drag, so they stay valid for the whole gesture).
    private func dismissDrag(pageSize: CGSize, pageGlobalFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard isCurrent, !isScrubbing, !dismissing, !zoomed, magnify == 1 else { return }
                // Drags must start on the media, not on the bottom
                // chrome (progress bar + toolbar when the chrome is
                // shown; only the Home Indicator strip when hidden).
                let chromeZone: CGFloat = chromeVisible ? 140 : 40
                guard value.startLocation.y < pageSize.height - chromeZone else { return }
                let dy = value.translation.height
                // Direction lock: once the drag has claimed the touch
                // (the media is already moving down), keep following
                // the vertical component even if the finger drifts
                // sideways.
                let claimed = dragOffset.height > 0
                guard dy > 0, claimed || abs(dy) > abs(value.translation.width) else { return }
                dragOffset = CGSize(width: 0, height: dy)
                dragScale = 1 - 0.35 * min(dy / 300, 1)
            }
            .onEnded { value in
                guard isCurrent, !isScrubbing, !dismissing, !zoomed, magnify == 1 else {
                    resetDismissDrag()
                    return
                }
                let dy = value.translation.height
                let vertical = dy > 0 && (dragOffset.height > 0 || abs(dy) > abs(value.translation.width))
                // Distance OR flick: a fast downward flick dismisses
                // even from a short drag. `predictedEndTranslation`
                // is the flick proxy (it extrapolates from the
                // finger's velocity): > 300pt down means the finger
                // was heading well past the threshold. (`velocity`
                // itself is not used — its public availability on
                // DragGesture.Value is contested; predicted-end is
                // public since iOS 13.)
                let flick = value.predictedEndTranslation.height > 300
                if vertical && (dy > 120 || flick) {
                    dismissToThumbnail(pageSize: pageSize, pageGlobalFrame: pageGlobalFrame)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = .zero
                        dragScale = 1
                    }
                }
            }
    }

    /// Release past the threshold: animate the media onto its source
    /// thumbnail (or down off the screen when the thumbnail is
    /// unknown), fade the background + chrome out, then close the
    /// overlay. The close happens in the animation's completion, so
    /// the media visibly shrinks onto the thumbnail instead of
    /// vanishing mid-flight — and because the overlay is just
    /// removed (no NavigationStack pop), nothing slides across the
    /// screen afterwards.
    private func dismissToThumbnail(pageSize: CGSize, pageGlobalFrame: CGRect) {
        let target = dismissTarget(pageSize: pageSize, pageGlobalFrame: pageGlobalFrame)
        withAnimation(.easeInOut(duration: 0.35)) {
            dragOffset = target.offset
            dragScale = target.scale
            dismissing = true
        } completion: {
            onDismiss?()
        }
    }

    /// Where the media flies to on a dismissing release: its source
    /// thumbnail (the media scales to cover it, centred on it — the
    /// grid cell shows the media cropped to fill the square, so the
    /// landing image lines up with the thumbnail), or — when the
    /// thumbnail is unknown (opened from Search / For You) — down
    /// off the bottom edge while shrinking + fading.
    private func dismissTarget(pageSize: CGSize, pageGlobalFrame: CGRect) -> (offset: CGSize, scale: CGFloat) {
        guard let thumb = sourceFrame, thumb.width > 0, thumb.height > 0 else {
            return (CGSize(width: 0, height: pageSize.height), 0.6)
        }
        // The drawn media size: a video fills the page (aspectFill);
        // a photo is aspect-fit inside it.
        let drawn: CGSize
        if isImage {
            let imageSize: CGSize
            if let fullImage {
                imageSize = fullImage.size
            } else if let w = item.width, let h = item.height, w > 0, h > 0 {
                imageSize = CGSize(width: w, height: h)
            } else {
                imageSize = pageSize
            }
            let fitted = AVMakeRect(aspectRatio: imageSize, insideRect: CGRect(origin: .zero, size: pageSize)).size
            drawn = (fitted.width > 0 && fitted.height > 0) ? fitted : pageSize
        } else {
            drawn = pageSize
        }
        // Cover the thumbnail (see above): the largest ratio wins.
        let scale = max(thumb.width / drawn.width, thumb.height / drawn.height)
        let pageCenter = CGPoint(x: pageGlobalFrame.midX, y: pageGlobalFrame.midY)
        let offset = CGSize(width: thumb.midX - pageCenter.x, height: thumb.midY - pageCenter.y)
        return (offset, max(scale, 0.05))
    }

    /// Instantly clear a half-started dismiss drag (the gesture
    /// ended while gated off — zoomed, scrubbing, or a pinch in
    /// progress). No animation: the media never visibly moved.
    private func resetDismissDrag() {
        dragOffset = .zero
        dragScale = 1
    }

    private func doubleTap() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            scale = scale > 1.05 ? 1 : 2.6
            zoomed = scale > 1.05
        }
        Haptics.tap()
    }

    // MARK: - Player (FeedView's setup, reused as-is)

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
            guard !isScrubbing else { return }
            currentTime = time.seconds
            let total = newPlayer.currentItem?.duration.seconds ?? 0
            if total.isFinite && total > 0 { duration = total }
            // Loop: replays the video when it ends. Done here (not
            // with a NotificationCenter observer) so nothing leaks
            // when the player is kept across swipes.
            if isPlaying, total > 0, time.seconds >= total - 0.25 {
                seek(to: 0)
            }
        }
    }

    /// Seek to the current frame (restart from the top if the video
    /// already ended) and play at the chosen speed. The seek is what
    /// makes the layer render a frame instead of staying
    /// frozen/black.
    private func playCurrent() {
        guard let player, isCurrent else { return }
        let rate = playbackRate
        let target: CMTime
        if duration > 0 && currentTime >= duration - 0.5 {
            target = .zero
        } else {
            target = player.currentTime()
        }
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            player?.rate = rate
        }
        isPlaying = true
    }

    /// Auto-play (user decision, round 3): a video starts playing
    /// when its page opens or is swiped to. Photos are unaffected.
    /// Called from onAppear (opening page) and onChange(isCurrent)
    /// (paging onto a page). `setupPlayer` is a no-op when the
    /// player already exists; `playCurrent` is a no-op when the
    /// player is missing or the page is not current. Paging away
    /// pauses in onChange(isCurrent)'s else branch and in
    /// onDisappear — unchanged.
    private func playIfVideo() {
        guard !isImage, item.status == .ready else { return }
        setupPlayer()
        playCurrent()
    }

    /// Playback speed from the running-person button. Applies immediately
    /// when the video is playing; otherwise it applies on resume.
    private func selectRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    /// "Share" (toolbar): download the video (or image) file, then
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
        } else {
            playCurrent()
        }
    }

    /// Mute/unmute this page's player (speaker icon in the toolbar).
    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    /// One icon button in the Photos-style bottom toolbar: a blue
    /// 22pt icon, evenly spread (each button takes an equal share
    /// of the width). 50pt tall, like the Photos toolbar.
    private func playerTabButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            currentTime = seconds
        }
    }

    /// Progress bar visibility (Photos): the bar stays visible
    /// whenever the chrome is shown — no auto-hide timer. Called on
    /// every interaction (tap, page appearing, scrub ending) so the
    /// bar is visible again after any chrome toggle.
    private func showControlsTemporarily() {
        controlsVisible = true
    }

    /// Seek from a progress-bar scrub. Clears isScrubbing only in the
    /// seek's completion — AFTER the player is at the new position.
    /// The isScrubbing=false change resumes playback (only if it was
    /// playing before the scrub), and if that runs before the seek
    /// lands it seeks the player back to the old position (the bar
    /// "jumps back" to where it was). Clearing it here makes the
    /// resume a no-op (the player is already at the new position)
    /// and the video resumes from the scrubbed spot.
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
/// grid context menus ("Add to Album") — presented as its own
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
                Text(L10n.addToCollection)
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
                                    Text(L10n.collectionVideoCount(collection.count))
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
                        TextField(L10n.newCollectionName, text: $newCollectionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                        Button(L10n.create) {
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
            pickerError = L10n.addToCollectionFailed
        }
    }

    private func createAndAdd() async {
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isAdding else { return }
        isAdding = true
        pickerError = nil
        defer { isAdding = false }
        guard let created = await viewModel.createMyCollection(name: name) else {
            pickerError = L10n.createCollectionFailed
            return
        }
        if let added = await viewModel.addItemToMyCollection(collectionId: created.id, item: item) {
            onAddedToCollection(created.name, added)
            dismiss()
        } else {
            pickerError = L10n.createdButNotAdded(created.name)
        }
    }
}


/// Thin progress bar at the very bottom edge of a viewer page: a 2pt line — track white 30%, played portion white.
/// Dragging scrubs; while dragging, a preview popup (sprite frame at
/// that timestamp + time) floats above the bar. The touch area is
/// taller than the visible line so it is easy to grab.
/// Facebook Reels-style progress bar for the full-screen viewer.
///
/// - Visibility (Photos): the bar is visible whenever the chrome is
///   shown — it never fades out on its own (this view only reads
///   `controlsVisible`). While scrubbing it is always visible.
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
    /// False when the chrome is hidden. The bar fades out with the
    /// chrome, but the 64pt touch area stays live so the user can still
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

    /// True while the bar should be on screen (chrome shown, or
    /// scrubbing — which forces it visible even when the chrome is
    /// hidden).
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
                // scrubbing (Facebook Reels). Fades out with the
                // chrome (barVisible), fades back in when it shows.
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
            // so the toolbar below does not move. Combined with the
            // high-priority gesture and scrollDisabled while
            // scrubbing, a touch starting anywhere near the bar
            // scrubs instead of paging.
            .frame(height: 64, alignment: .bottom)
            .contentShape(Rectangle())
            // High-priority: the viewer is a horizontal paging ScrollView
            // and it sometimes steals this drag (the bar "misses" the
            // scrub). A plain .gesture loses to the ScrollView when the
            // finger moves even slightly vertical; high-priority makes
            // a touch that starts on the bar always scrub. The bar is
            // only 64pt tall at the very bottom, so vertical swipes
            // starting elsewhere still page normally.
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
/// edge) in the viewer and the album details, alongside their
/// ScrollViews. No custom DragGesture is used anywhere — the back
/// swipe is the system's own interactive pop.
///
/// Two things block the native pop, and this fixes both:
/// 1. The ScrollView claims the touch, so the navigation
///    controller's edge pan never fires. Fix (UIKit, the standard
///    pattern for ScrollView + pop): make the scroll view's pan
///    gesture wait — it only recognizes if the edge pan fails.
///    A rightward pan from the left edge then pops natively; a
///    vertical pan fails the edge pan immediately, so the viewer
///    still pages and the grid still scrolls (album).
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
/// Fades the REAL UITabBar in/out with the drag-down-to-dismiss
/// progress (Photos cross-fade): the viewer toolbar fades out with
/// `chromeOpacity` while the app tab bar fades in with the same
/// `dragProgress`, so the two bars cross-fade in sync. SwiftUI
/// cannot fade a tab bar — `.toolbar(.hidden/.visible)` only snaps
/// it — so this bridge finds the TabView's UITabBarController (the
/// helper is a child of the hosting controller, so the
/// `tabBarController` property walks straight to it) and drives
/// `tabBar.alpha`.
///
/// The tab bar is NEVER interactive while the viewer is open (the
/// viewer owns the screen; the tab bar is only a visual fading in
/// over the grid) — hit-testing stays off until the viewer goes
/// away. The alpha is always restored to 1 when the viewer is
/// removed (`didMove(toParent: nil)` + `dismantleUIViewController`),
/// so no close path — drag release, delete-last-item, or anything
/// else — can leave the tab bar invisible. The tab bar is cached
/// weakly on first use because `tabBarController` no longer
/// resolves once the helper has left the hierarchy.
struct TabBarFadeHelper: UIViewControllerRepresentable {
    /// 0 = tab bar fully transparent, 1 = fully visible.
    var alpha: CGFloat

    func makeUIViewController(context: Context) -> TabBarFadeController {
        TabBarFadeController(alpha: alpha)
    }

    func updateUIViewController(_ uiViewController: TabBarFadeController, context: Context) {
        uiViewController.alpha = alpha
        uiViewController.applyAlpha()
    }

    static func dismantleUIViewController(_ uiViewController: TabBarFadeController, coordinator: ()) {
        uiViewController.restore()
    }
}

final class TabBarFadeController: UIViewController {
    var alpha: CGFloat
    /// The tab bar, cached weakly on first use (see above).
    private weak var tabBar: UITabBar?

    init(alpha: CGFloat) {
        self.alpha = alpha
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Empty helper view: never intercept touches.
        view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            // Removed with the viewer overlay: restore the tab bar
            // before the next frame renders the grid.
            restore()
        } else {
            applyAlpha()
        }
    }

    /// Set the tab bar's alpha (and keep it non-interactive while
    /// the viewer is open — the viewer owns the screen).
    func applyAlpha() {
        if tabBar == nil { tabBar = tabBarController?.tabBar }
        guard let tabBar else { return }
        tabBar.alpha = alpha
        tabBar.isUserInteractionEnabled = false
    }

    /// Back to normal: fully visible and tappable.
    func restore() {
        if tabBar == nil { tabBar = tabBarController?.tabBar }
        guard let tabBar else { return }
        tabBar.alpha = 1
        tabBar.isUserInteractionEnabled = true
    }
}

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
        // ScrollView — the paging viewer or the grid
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
