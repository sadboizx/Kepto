import SwiftUI
import UIKit

/// Video-only or photo-only browser (opened from the Albums tab's
/// Media Types rows). The API's `media` filter is "video" /
/// "image"; this enum is the Swift-side spelling.
enum MediaKind: String, Hashable {
    case video, photo
}

/// What one `PhotoCollectionScreen` shows. The three old detail
/// views (per-creator `CollectionDetailView`, user-collection
/// `MyCollectionDetailView`, built-in `AlbumItemsView`) are all the
/// same grid with a different source — Photos' `PhotoCollectionScreen`
/// is that one grid, and this enum is how Kepto picks the source.
/// Media Types rows open the same browser with a media filter.
enum AlbumSource: Hashable {
    /// Built-in album — only `.recents` / `.favorites` are ever
    /// constructed (the other `AlbumKind` cases are section kinds,
    /// not browser sources).
    case kind(AlbumKind)
    case myCollection(MyCollection)
    case creator(CollectionInfo)
    case media(MediaKind)
}

/// One album's items: a square grid (Photos style, 2 or 3 columns by
/// screen width), newest first. Tapping an item opens it in the
/// full-screen feed (swipe up/down for the next item in this album).
/// Pull-to-refresh reloads. Long-press a cell opens the native iOS
/// context menu (Save to Photos / Share / Favorite / Add to Album /
/// Delete; user collections also get Remove from Album). Select mode
/// uses Photos' `SelectBottomBar` (Share / Favorite / Add / Delete +
/// a "More" menu with Save to Photos).
///
/// The toolbar keeps Kepto's "Select" pill + "…" menu when not
/// selecting; user collections get Rename Album + Delete Album in
/// the "…" menu, other albums get Settings. While selecting, the
/// toolbar shows Photos' Cancel + Select All instead.
struct PhotoCollectionScreen: View {
    let source: AlbumSource
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [Item] = []
    /// Round-13: `sortedItems` used to re-sort the loaded pages on
    /// every access (per cell appear, per body eval) — the same
    /// per-access cost as the Library's allIDs, over a smaller list.
    /// Cached here, rebuilt once per `items` change.
    @State private var cachedSortedItems: [Item] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// The item the feed opens on (nil = feed closed).
    @State private var feedStartItem: Item?
    /// Initial scroll to the bottom (newest, Apple Photos): the
    /// album opens on the newest item. See maybeInitialScroll.
    @State private var didInitialScroll = false
    /// True while the last (newest) cell is on screen — i.e. the
    /// user is at the bottom. Gates the new-item follow scroll.
    @State private var isAtBottom = false
    /// The global frame of the thumbnail the viewer opened from
    /// (nil = unknown): the viewer's dismiss drag shrinks the media
    /// onto it on release. Read from `cellFrameCache` at tap time.
    @State private var feedStartFrame: CGRect?
    /// Live cache of grid-cell global frames (see
    /// `CellFrameCache`): written by the cells' preference, read
    /// only when a cell is tapped.
    @State private var cellFrameCache = CellFrameCache()
    /// The grid's ScrollView proxy, kept so the viewer's
    /// `onCurrentItemChange` can scroll the grid to the current
    /// thumbnail (same pattern as LibraryView's `scrollProxy`).
    @State private var scrollProxy: ScrollViewProxy?
    /// The grid's visible viewport (same pattern as LibraryView):
    /// the viewer-follow check scrolls unless the current cell is
    /// fully inside it.
    @State private var scrollViewport: CGRect = .zero
    /// Height of the top chrome (status bar + nav bar), measured
    /// live while it is visible and latched at its max (same pattern
    /// as LibraryView's `topChromeHeight`, round-17): the grid
    /// ignores the top safe area (see `collectionGrid`) and uses
    /// this as a fixed top content margin instead, so the first row
    /// starts below the nav bar instead of hiding under it
    /// (round-19) — and opening/closing the viewer never moves the
    /// grid, because the margin does not change when the chrome
    /// hides.
    @State private var topChromeHeight: CGFloat = 0
    /// Items resolved for the slideshow (empty = closed).
    @State private var slideshowItems: [Item] = []
    @State private var showingSlideshow = false
    /// The item the context menu's "Add to Album" opened the picker
    /// for (nil = picker closed).
    @State private var itemForAlbumPicker: Item?
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// Downloaded files for the bulk share sheet.
    @State private var shareURLs: [URL] = []
    @State private var showingBulkShare = false
    /// The item awaiting delete confirmation from the grid menu.
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false
    @State private var showingDeleteCollection = false
    /// Rename flow: the alert's text field + whether it is open.
    @State private var showingRename = false
    @State private var renameText = ""
    /// The name after a rename (nil = still the original). The view
    /// receives a `MyCollection` snapshot, so the navigation title
    /// reads this to update in place after renaming.
    @State private var renamedName: String?
    @State private var removeError: String?
    /// Multi-select mode for bulk actions (same pattern as the
    /// Library grid): tap toggles selection, the bottom bar is
    /// Photos' SelectBottomBar.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    /// Drag-to-select state (see `DragSelectTracker`): reset on
    /// gesture end and on leaving select mode.
    @State private var dragSelect = DragSelectTracker()
    @State private var showingBulkDeleteConfirmation = false
    /// Presents the Settings sheet from the "…" menu.
    @State private var showingSettings = false
    /// Presents Photos' Add to Album sheet for the selection.
    @State private var showingAddToAlbum = false

    /// Detail-grid columns: 2 on narrow screens, 3 on wide ones
    /// (spec: "2 hoặc 3 cột tùy kích thước màn hình"). iPhone 12 Pro
    /// Max (428pt) gets 3; iPhone SE / 12 (375–390pt) get 2.
    private var columns: [GridItem] { albumGridColumns() }

    /// The title in the navigation bar.
    private var title: String {
        switch source {
        case .kind(let kind):
            return kind.title
        case .myCollection(let collection):
            return renamedName ?? collection.name
        case .creator(let collection):
            return collection.displayName
        case .media(let media):
            return media == .video ? L10n.videos : L10n.photos
        }
    }

    /// Round-31: re-tap counter from the tab bar (shared with the
    /// Albums list) + a pop callback. While inside an album a
    /// re-tap scrolls to the bottom, or pops to the Albums list
    /// when already at the bottom.
    @Binding var retapRequest: Int
    var onRequestPop: (() -> Void)? = nil

    /// Pre-seeded items (round-30): the parent computes the seed
    /// from the caches at tap time, so the FIRST frame already shows
    /// real cells. Without this the grid opened empty and only
    /// filled in onAppear — in short albums that late layout left
    /// taps dead until the first scroll forced a pass. The seed is
    /// pure and cheap (round-29 sort), so computing it here costs
    /// no more than the onAppear seed it replaces.
    init(source: AlbumSource, initialItems: [Item] = [], retapRequest: Binding<Int> = .constant(0), onRequestPop: (() -> Void)? = nil) {
        self.source = source
        _items = State(initialValue: initialItems)
        _cachedSortedItems = State(initialValue: initialItems.sortedChronologically())
        _retapRequest = retapRequest
        self.onRequestPop = onRequestPop
    }

    var body: some View {
        collectionWithNavigation
            // Round-31: re-tap on the Albums tab while inside an
            // album — case B scrolls to the bottom, case C (already
            // at the bottom) pops to the Albums list. The list's
            // own handler (AlbumsView) does nothing while this
            // detail is open.
            .onChange(of: retapRequest) { _, _ in
                // The tab bar is invisible while the viewer is open,
                // so a real tap cannot land then — this is
                // belt-and-braces (and matches scrollToBottomAnimated's
                // own guard): never pop the detail from behind the
                // viewer.
                guard feedStartItem == nil else { return }
                if isAtBottom {
                    onRequestPop?()
                } else {
                    scrollToBottomAnimated()
                }
            }
            .confirmationDialog(L10n.deleteSavedItemsTitle(1),
                                isPresented: $showingDeleteConfirmation,
                                titleVisibility: .visible) {
                Button(L10n.delete, role: .destructive) {
                    Task { await deleteGridMenuItem() }
                }
                Button(L10n.cancel, role: .cancel) { itemPendingDelete = nil }
            } message: {
                Text(itemPendingDelete?.displayTitle ?? "")
            }
            .confirmationDialog(L10n.deleteSavedItemsTitle(selectedIDs.count),
                                isPresented: $showingBulkDeleteConfirmation,
                                titleVisibility: .visible) {
                Button(L10n.delete, role: .destructive) {
                    Task { await deleteSelected() }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.deleteFromCloudMessage)
            }
    }

    /// Navigation + sheets over the grid: the viewer overlay, the
    /// slideshow cover, and the four sheets (Add to Album picker,
    /// single share, bulk share, Add to Album sheet). A separate
    /// property so the compiler type-checks it apart from `body`.
    private var collectionWithNavigation: some View {
        collectionWithAlerts
            // Viewer as a full-screen OVERLAY over this grid, not a
            // push — see PhotoDetailView's header comment for why
            // (a push's hosting layer is opaque: the grid never
            // showed through the fading background, and the pop slid
            // a black bar across the screen).
            .overlay {
                if let startItem = feedStartItem {
                    PhotoDetailView(
                        items: $items,
                        startItemId: startItem.id,
                        onNearEnd: { await loadMore() },
                        title: title,
                        sourceFrame: feedStartFrame,
                        onDismiss: {
                            feedStartItem = nil
                            // Defer the flag merge past the swap
                            // frame (round-9): re-rendering the grid
                            // in the same frame the overlay vanishes
                            // would pop the target cell's heart on at
                            // the landing instant. 0.15s later the
                            // grid is settled and the heart update is
                            // invisible. The merge is idempotent, so
                            // a fast re-open in between is harmless.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                items = viewModel.applyingMetadataFavoriteFlags(to: items)
                            }
                        },
                        // Live frame lookup for the close (round-9):
                        // the viewer re-queries the cell's frame at
                        // release instead of trusting the tap-time
                        // capture. The cache is a class, so the
                        // closure always sees the current frames.
                        frameLookup: { [cellFrameCache] id in cellFrameCache.frames[id] },
                        // Follow the viewer's current item in the
                        // background grid (Apple Photos): while the
                        // user pages, the grid scrolls the current
                        // thumbnail into view — only when it is
                        // off-screen, so a visible cell never moves.
                        onCurrentItemChange: { id in scrollGridToCurrentItem(id: id) }
                    )
                    .ignoresSafeArea()
                }
            }
            .fullScreenCover(isPresented: $showingSlideshow) {
                SlideshowView(items: slideshowItems)
            }
            .sheet(item: $itemForAlbumPicker) { pickerItem in
                AddToCollectionPickerView(
                    item: pickerItem,
                    onAddedToCollection: { _, _ in },
                    onCancel: { itemForAlbumPicker = nil }
                )
            }
            .sheet(item: $shareFile) { file in
                ShareSheet(activityItems: [file.url])
            }
            .sheet(isPresented: $showingBulkShare) {
                ShareSheet(activityItems: shareURLs)
            }
            .sheet(isPresented: $showingAddToAlbum) {
                AddToAlbumSheet(ids: Array(selectedIDs))
            }
    }

    /// Alerts + the delete-album dialog over the grid. Kept apart
    /// from `body` for the same type-checking reason.
    private var collectionWithAlerts: some View {
        collectionGridWithToolbar
            .alert("Kepto", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            // (Bulk-action notices are toasts now — no local alert.)
            .alert(L10n.removeFailed, isPresented: .constant(removeError != nil)) {
                Button("OK") { removeError = nil }
            } message: {
                Text(removeError ?? "")
            }
            .alert(L10n.renameAlbum, isPresented: $showingRename) {
                TextField(L10n.albumName, text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.rename) {
                    Task { await renameCollection() }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.renameAlbumMessage)
            }
            .confirmationDialog(L10n.deleteAlbumTitle(title),
                                isPresented: $showingDeleteCollection,
                                titleVisibility: .visible) {
                Button(L10n.deleteAlbumAndVideos, role: .destructive) {
                    Task { await deleteCollection(deleteItems: true) }
                }
                Button(L10n.deleteAlbumOnly, role: .destructive) {
                    Task { await deleteCollection(deleteItems: false) }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                if case .myCollection(let collection) = source {
                    Text(L10n.deleteAlbumMessage(collection.count))
                }
            }
    }

    /// The grid with its toolbar and chrome modifiers (nav title,
    /// Settings sheet, bottom select bar, refresh, loading/empty
    /// overlay). The toolbar items stay inlined here at the call
    /// site — never a `toolbarContent` property (Photos lesson:
    /// the compiler cannot tell it from the `.toolbar` modifier).
    private var collectionGridWithToolbar: some View {
        collectionGrid
            // Native pop gesture: make this grid's ScrollView defer to
            // the edge pan, so the swipe-back starts at once instead of
            // hesitating while the system decides (smoother pop).
            .background(NativePopGestureHelper())
            // While selecting, the back button and the title hide and
            // the toolbar shows Select All (pill, left) + Cancel
            // (pill, right). The swipe-back gesture still works while
            // the back button is hidden — NativePopGestureHelper
            // (above) permits it whenever there is a view to pop to
            // (same as the See All Edit mode).
            .navigationTitle(isSelecting ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isSelecting)
            // Transparent status bar / nav bar (see AlbumsView).
            .toolbarBackground(.hidden, for: .navigationBar)
            // While the viewer overlay is open, hide the navigation
            // bar and the status bar: the viewer's own
            // .statusBarHidden does not take effect inside an
            // overlay in a NavigationStack, so it has to be set
            // here, on the opener. Both return the moment the
            // viewer closes (feedStartItem = nil). The grid already
            // extends under the bar, so hiding it does not move the
            // cells — the viewer's thumbnail target stays valid.
            .toolbar(feedStartItem == nil ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(feedStartItem != nil)
            // Measure the top chrome height while it is visible
            // (status bar + nav bar); latched at its max so the
            // ScrollView's fixed top margin stays put when the
            // viewer hides the chrome (round-19, same as LibraryView).
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { newTop in
                if newTop > topChromeHeight { topChromeHeight = newTop }
            }
            // The system back button ("< Albums") is white via
            // .tint(.primary) on the AlbumsView NavigationStack (the tint
            // comes from the stack, not the pushed view). It shows
            // only when not selecting.
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            if selectedIDs.count == items.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(items.map(\.id))
                            }
                        } label: {
                            Text(selectedIDs.count == items.count ? L10n.deselectAll : L10n.selectAll)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { exitSelectionMode() } label: {
                            Text(L10n.cancel)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 8) {
                            // Photos style: "Select" is a dark pill with
                            // white footnote text, like the Library tab.
                            Button {
                                toggleSelecting()
                            } label: {
                                Text(L10n.select)
                                    .font(.footnote)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            trailingMenu
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    selectBar
                }
            }
            .refreshable {
                await fetch(reset: true)
            }
            .task {
                // Kick the full-metadata fetch off in parallel: the
                // flag merge needs the cache, and the user may open
                // Albums before the Library tab ever loads it.
                Task { await viewModel.fetchAllMetadata() }
                await fetch(reset: true)
                // Round-26: prefetch this album's thumbnails now
                // that the page is in (visible items first).
                viewModel.prefetchMissingThumbnails(ids: items.map(\.id))
            }
            .onChange(of: viewModel.allMetadataLoaded) { _, loaded in
                // The cache arrived after the grid opened: if the
                // grid is still empty, seed it now (round-21) — the
                // grid appears without waiting for the page fetch.
                // Otherwise overlay its favorite flags (idempotent).
                if loaded {
                    if items.isEmpty {
                        seedItemsFromCache()
                    } else {
                        items = viewModel.applyingMetadataFavoriteFlags(to: items)
                    }
                }
            }
            .overlay {
                // No full-screen spinner while loading (round-21):
                // the skeleton grid inside the ScrollView is the
                // loading state when the cache is cold; with a warm
                // cache the grid is already seeded, so `items` is
                // never empty here.
                if items.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySymbol)
                    } description: {
                        Text(emptyDescription)
                    }
                }
            }
    }

    /// The grid itself: square cells (Photos style) + the load-more
    /// footer. Extracted so the compiler type-checks the ForEach
    /// (cells + context menu + onAppear) apart from the modifiers.
    /// The grid renders `sortedItems` (oldest first, Apple Photos);
    /// the underlying `items` stays in server order (newest first)
    /// so the viewer, load-more and the favorite merge keep working
    /// exactly as before.
    private var sortedItems: [Item] { cachedSortedItems }

    /// Rebuild the sorted-items cache from the loaded pages.
    private func refreshSortedItems() {
        cachedSortedItems = items.sortedChronologically()
    }

    /// Seed the grid from the `listAll` metadata cache (round-21,
    /// stale-while-revalidate): the album renders instantly from
    /// cached metadata while the first page loads in the background.
    /// Only the NEWEST page window (50, like the API page) is seeded
    /// — that is the region the bottom-anchored first frame shows;
    /// older items keep lazy-loading via load-more exactly as before.
    /// The background fetch() replaces these seeds with the real
    /// Items (same ids, same order), in place — no flash, no jump.
    /// No-op when items are already loaded or the cache is cold.
    /// Pure seed (round-30): the newest 50 for this source from the
    /// metadata cache, else from the Library's loaded first page.
    /// Static so the parent can pre-seed before the first frame —
    /// the grid then opens with real cells instead of an empty grid
    /// that only fills in onAppear (whose late layout left taps dead
    /// in short albums until the first scroll forced a pass).
    static func seedItems(source: AlbumSource, allMetadata: [ItemMetadata], libraryItems: [Item]) -> [Item] {
        // Metadata cache first (round-21): newest 50 in server order.
        if !allMetadata.isEmpty {
            let matching = allMetadata.filter { matchesSource($0, source: source) }
            if !matching.isEmpty {
                // Server order (newest first): the display sort is ascending,
                // so reverse it — same ids and order the first page returns.
                let newest = matching.sortedChronologically().reversed().prefix(50)
                return newest.map { Item(seededFrom: $0) }
            }
        }
        // Round-25: the metadata cache may still be downloading
        // (first launch, or the user tapped fast) — seed from the
        // Library's already-loaded first page instead (newest 50,
        // same server order). Item carries contentType/isFavorite/
        // authorUsername, so Recents / Favorites / Media / Creator
        // seed exactly; My Collection has no ids on Item, so it
        // waits for the page fetch as before.
        let matching = libraryItems.filter { matchesSource($0, source: source) }
        guard !matching.isEmpty else { return [] }
        return Array(matching.prefix(50))
    }

    private func seedItemsFromCache() {
        guard items.isEmpty else { return }
        let seeded = Self.seedItems(source: source, allMetadata: viewModel.allMetadata, libraryItems: viewModel.items)
        guard !seeded.isEmpty else { return }
        items = seeded
        refreshSortedItems()
    }

    /// True when a cached metadata row belongs to this album.
    private static func matchesSource(_ m: ItemMetadata, source: AlbumSource) -> Bool {
        switch source {
        case .kind(.recents):
            return true
        case .kind(.favorites):
            return m.isFavorite
        case .kind(.user), .kind(.people), .kind(.media), .kind(.deleted):
            // Section kinds, never a browser source — nothing to seed.
            return false
        case .myCollection(let collection):
            return m.myCollectionIds.contains(collection.id)
        case .creator(let collection):
            return m.authorUsername == collection.id
        case .media(.video):
            return m.contentType?.hasPrefix("video/") == true
        case .media(.photo):
            return m.contentType?.hasPrefix("image/") == true
        }
    }

    /// Round-25: same filter over a real `Item` (the Library's
    /// loaded first page) — used when the metadata cache has not
    /// landed yet. My Collection cannot seed from Items (no
    /// collection ids on Item), so it returns false here.
    private static func matchesSource(_ item: Item, source: AlbumSource) -> Bool {
        switch source {
        case .kind(.recents):
            return true
        case .kind(.favorites):
            return item.isFavorite
        case .kind(.user), .kind(.people), .kind(.media), .kind(.deleted):
            // Section kinds, never a browser source — nothing to seed.
            return false
        case .myCollection:
            return false
        case .creator(let collection):
            return item.authorUsername == collection.id
        case .media(.video):
            return item.contentType?.hasPrefix("video/") == true
        case .media(.photo):
            return item.contentType?.hasPrefix("image/") == true
        }
    }

    private var collectionGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(sortedItems) { item in
                            PhotosGridCell(
                                item: item,
                                isSelectionMode: isSelecting,
                                isSelected: selectedIDs.contains(item.id),
                                onTap: {
                                    if isSelecting {
                                        toggleSelection(item)
                                    } else {
                                        // Capture the tapped cell's frame
                                        // before opening: the viewer's
                                        // dismiss drag shrinks the media
                                        // onto it.
                                        feedStartFrame = cellFrameCache.frames[item.id]
                                        feedStartItem = item
                                    }
                                }
                            )
                            .contextMenu {
                                GridItemContextMenu(
                                    item: item,
                                    isSelecting: isSelecting,
                                    onSaveToPhotos: { saveToPhotos($0) },
                                    onShare: { shareItem($0) },
                                    onToggleFavorite: { toggleGridFavorite($0) },
                                    onAddToAlbum: { itemForAlbumPicker = $0 },
                                    onDelete: { requestGridDelete($0) },
                                    onRemoveFromCollection: sourceIsMyCollection ? { item in
                                        Task { await removeFromCollection(item) }
                                    } : nil
                                )
                            }
                            .onAppear {
                                // Load-more fires at the OLDEST end
                                // (top): the server pages go older, so
                                // the oldest loaded cell appearing
                                // means the user scrolled up into
                                // not-yet-loaded items.
                                if item.id == sortedItems.first?.id {
                                    Task { await loadMore() }
                                }
                                if item.id == sortedItems.last?.id { isAtBottom = true }
                            }
                            .onDisappear {
                                if item.id == sortedItems.last?.id { isAtBottom = false }
                            }
                        }
                    }
                    if sortedItems.isEmpty && isLoading {
                        // Cold cache (first-ever open): gray placeholder
                        // cells in the exact grid layout — no
                        // full-screen spinner, no layout flash when the
                        // real cells land (round-21).
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(0..<12, id: \.self) { _ in
                                Color(.systemGray5)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                    if nextCursor != nil {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                            } else {
                                Button(L10n.loadMore) {
                                    Task { await loadMore() }
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            // The grid must not move when the viewer closes
            // (round-17): while the viewer is open the nav bar +
            // status bar are hidden, so the top safe-area inset is
            // 0; when they come back the inset grows by ~91pt and
            // the ScrollView's offset compensation for it lands a
            // frame late — the grid jerks up slightly at the swap
            // instant. The 0.15s deferred merge was exonerated
            // (the device video shows the grid pixel-stable across
            // it). Ignoring the top safe area pins the content
            // inset to 0 in both states, so the bars returning
            // cannot move the content at all. The fixed top margin
            // below (round-19) replaces the inset: without it the
            // first row sat at y = 0, half-hidden under the
            // transparent nav bar (the Favorites 1-item screenshot
            // proves it — the only cell is stuck under the chrome).
            // The margin is latched at max (see `topChromeHeight`),
            // so it never changes while the viewer hides the chrome.
            // Open at the BOTTOM (newest) from the very first frame
            // (round-20): `.defaultScrollAnchor(.bottom)` (iOS 17+)
            // is a layout anchor, not a scroll — the ScrollView lays
            // out with its content pinned at the bottom edge, so
            // there is no onAppear scrollTo, no flash at the top and
            // no slide-down. The old `maybeInitialScroll` scrollTo
            // calls stay as a belt-and-braces fallback (they no-op
            // once the view is already at the bottom) and still set
            // the flags `maybeScrollToNewItem` needs. As async data
            // lands, the anchor keeps the bottom pinned (new content
            // grows upward); pull-to-refresh swaps the page in place
            // (`items = page`, never emptied first), so it does not
            // reset the position — and a mid-list user is not yanked
            // when items append below the viewport. Load-more
            // prepends OLDER pages at the top; the anchor keeps the
            // visible content stable (no jump).
            .ignoresSafeArea(edges: .top)
            .defaultScrollAnchor(.bottom)
            .contentMargins(.top, topChromeHeight, for: .scrollContent)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { scrollViewport = $0 }
            .simultaneousGesture(dragSelectGesture)
            // The cells report their global frames (see
            // `PhotosGridCell`): keep them in the cache so a tap can hand
            // the tapped cell's frame to the viewer for its
            // shrink-to-thumbnail dismiss.
            .onPreferenceChange(CellFramePreferenceKey.self) { frames in
                cellFrameCache.frames.merge(frames) { _, new in new }
            }
            .onAppear {
                scrollProxy = proxy
                // Render from the cache first (round-21): the grid is
                // up before the first page returns.
                seedItemsFromCache()
                refreshSortedItems()
                // Round-26: prefetch thumbnails for this album's
                // items (delta load — cached ones are skipped).
                viewModel.prefetchMissingThumbnails(ids: items.map(\.id))
                maybeInitialScroll(proxy)
            }
            .onChange(of: items) { oldItems, newItems in
                let oldLast = cachedSortedItems.last?.id
                refreshSortedItems()
                maybeInitialScroll(proxy)
                maybeScrollToNewItem(proxy, oldLast: oldLast, newLast: cachedSortedItems.last?.id, oldCount: oldItems.count, newCount: newItems.count)
            }
        }
    }

    /// True when this browser shows a user-created collection (the
    /// only source with Remove from Album / Rename / Delete Album).
    private var sourceIsMyCollection: Bool {
        if case .myCollection = source { return true }
        return false
    }

    /// The "…" menu in the toolbar (hidden while selecting): Rename
    /// Album + Delete Album on a user collection, Settings elsewhere.
    /// Photos-style: a dark circle with a white ellipsis.
    @ViewBuilder
    private var trailingMenu: some View {
        if case .myCollection = source {
            Menu {
                Button {
                    if case .myCollection(let collection) = source {
                        renameText = renamedName ?? collection.name
                        showingRename = true
                    }
                } label: {
                    Label(L10n.renameAlbum, systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showingDeleteCollection = true
                } label: {
                    Label(L10n.deleteAlbum, systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .accessibilityLabel(L10n.moreOptions)
            }
        } else {
            Menu {
                Button { showingSettings = true } label: {
                    Label(L10n.settings, systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .accessibilityLabel(L10n.moreOptions)
            }
        }
    }

    /// (photos, videos, unknown) among the selection, for the
    /// bottom bar's center text. The album's items are fully
    /// loaded, so a selected id is always found — unknown stays 0
    /// unless an id somehow outlives its row.
    private var selectionKindCounts: (photos: Int, videos: Int, unknown: Int) {
        var byID: [String: Item] = [:]
        for item in items { byID[item.id] = item }
        var photos = 0, videos = 0, unknown = 0
        for id in selectedIDs {
            // `contentType` is optional, so the chain is Bool?? — a
            // switch over it is not exhaustive (the missing case is
            // a loaded item with a nil contentType). Flatten first:
            // unloaded id or nil type = unknown kind.
            guard let item = byID[id] else { unknown += 1; continue }
            if item.contentType?.hasPrefix("image/") == true {
                photos += 1
            } else if item.contentType == nil {
                unknown += 1
            } else {
                videos += 1
            }
        }
        return (photos, videos, unknown)
    }

    /// Bottom bar in multi-select mode: Photos' SelectBottomBar
    /// (Share / count / Delete / "…"). The "…" menu holds Save to
    /// Photos, Add to Album and Favorite, then Slideshow. (Photos'
    /// Hide / Duplicate entries are dropped — Hide and Duplicate
    /// were cut in Q3/Q4.)
    private var selectBar: some View {
        SelectBottomBar(
            photoCount: selectionKindCounts.photos,
            videoCount: selectionKindCounts.videos,
            unknownCount: selectionKindCounts.unknown,
            onShare: { Task { await shareSelection() } },
            onDelete: { showingBulkDeleteConfirmation = true }
        ) {
            Menu {
                Button { Task { await saveSelectionToPhotos() } } label: {
                    Label(L10n.saveToPhotos, systemImage: "arrow.down.to.line")
                }
                Button { showingAddToAlbum = true } label: {
                    Label(L10n.addToAlbum, systemImage: "rectangle.stack.badge.plus")
                }
                Button { Task { await favoriteSelection() } } label: {
                    Label(L10n.favorite, systemImage: "heart")
                }
                Button { presentSlideshow() } label: {
                    Label(L10n.slideshow, systemImage: "play.rectangle")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20))
            }
        }
    }

    /// Drag-to-select (Photos): in select mode a drag across cells
    /// selects/deselects them in bulk (see `DragSelectTracker`).
    /// `minimumDistance: 12` keeps tap-to-toggle intact, and
    /// `.simultaneousGesture` lets the ScrollView still scroll.
    private var dragSelectGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isSelecting else { return }
                selectedIDs = dragSelect.update(
                    start: value.startLocation,
                    current: value.location,
                    toGlobal: { CGPoint(x: scrollViewport.origin.x + $0.x, y: scrollViewport.origin.y + $0.y) },
                    frames: cellFrameCache.frames,
                    selection: selectedIDs
                )
            }
            .onEnded { _ in dragSelect.reset() }
    }

    /// Empty-state copy for this source.
    private var emptyTitle: String {
        switch source {
        case .kind(.favorites): return L10n.noFavoritesYet
        default: return L10n.noVideosYet
        }
    }

    private var emptySymbol: String {
        switch source {
        case .myCollection: return "folder"
        default: return "tray"
        }
    }

    private var emptyDescription: String {
        switch source {
        case .kind(.favorites):
            return L10n.favoriteHint
        case .kind(.recents):
            return L10n.videosWillAppearHere
        case .myCollection:
            return L10n.addFromFeedMenu
        case .creator(let collection):
            return L10n.videosFromCreator(collection.displayName)
        case .media(.video):
            return L10n.videosWillAppearHere
        case .media(.photo):
            return L10n.photosWillAppearHere
        case .kind:
            return L10n.videosWillAppearHere
        }
    }

    private func toggleSelecting() {
        if isSelecting {
            exitSelectionMode()
        } else {
            isSelecting = true
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIDs.removeAll()
        dragSelect.reset()
    }

    private func toggleSelection(_ item: Item) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// The full `Item` for one id: the loaded page first, else one
    /// fetch by id. Used by every action that needs more than the
    /// loaded grid row.
    private func resolveItem(id: String) async -> Item? {
        if let item = items.first(where: { $0.id == id }) { return item }
        return await viewModel.fetchItem(id: id)
    }

    /// Start the slideshow over the current selection, in grid order
    /// (Photos: the slideshow runs over the selected items). The
    /// selection only covers loaded rows, so no fetch is needed.
    private func presentSlideshow() {
        let resolved = sortedItems.filter { selectedIDs.contains($0.id) }
        guard !resolved.isEmpty else { return }
        slideshowItems = resolved
        showingSlideshow = true
    }

    // MARK: - Scroll to bottom (Apple Photos order)

    /// The viewer paged to another item: keep its thumbnail visible
    /// in the background grid (Apple Photos). Scrolls only when the
    /// cell is off-screen — a visible cell must not move under the
    /// viewer — and instantly (no animation), so the grid is already
    /// in place when the viewer closes. The viewport is the screen
    /// minus the tab bar (83pt: 49pt bar + 34pt Home indicator);
    /// the nav bar + status bar are hidden while the viewer is
    /// open, so the top edge is y = 0. An unknown frame (cell never
    /// laid out) still scrolls: `scrollTo` lays it out.
    private func scrollGridToCurrentItem(id: String) {
        guard let proxy = scrollProxy else { return }
        guard sortedItems.contains(where: { $0.id == id }) else { return }
        // Round-30: match LibraryView — scroll unless the cell is
        // FULLY inside the viewport. The old `intersects` test
        // skipped whenever any part showed, so paging to an adjacent
        // cell never re-centered and the grid lagged a page behind
        // (the "out of order" follow). An unknown frame still
        // scrolls: `scrollTo` lays it out.
        if let frame = cellFrameCache.frames[id] {
            let visible = scrollViewport.insetBy(dx: 0, dy: 8)
            if visible.contains(frame) { return }
        }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
    }

    /// Instant (no-animation) scroll to the bottom (newest item).
    /// The transaction disables animations outright — a plain
    /// scrollTo could otherwise visibly slide down on open.
    /// Round-31: animated scroll to the bottom (re-tap on the
    /// Albums tab while inside this album). Same guards as the
    /// Library's: no-op when already at the bottom, when the
    /// viewer is open, or when there is no target (empty album).
    private func scrollToBottomAnimated() {
        guard let proxy = scrollProxy, let id = sortedItems.last?.id, !isAtBottom, feedStartItem == nil else { return }
        withAnimation(.easeOut(duration: 0.4)) { proxy.scrollTo(id, anchor: .bottom) }
    }

    private func scrollToBottomInstant(_ proxy: ScrollViewProxy) {
        guard let id = sortedItems.last?.id else { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: .bottom) }
    }

    /// Scroll to the bottom (newest) once, instantly, on first open
    /// (Apple Photos opens on the newest photo). Fires when the
    /// first page is in; later pages are older, so the newest item
    /// stays the last one and no re-anchor is ever needed. Never
    /// fires while the viewer is open, and never on pull-to-refresh
    /// (fetch(reset:) leaves the order and the once-flag alone).
    private func maybeInitialScroll(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll, !sortedItems.isEmpty, feedStartItem == nil else { return }
        scrollToBottomInstant(proxy)
        didInitialScroll = true
    }

    /// A new item arrived at the end (bottom): if the user is at the
    /// bottom, follow it down smoothly; if they are mid-list, leave
    /// their scroll position alone. Only after the initial scroll —
    /// and never while the viewer or select mode is open. (Load-more
    /// appends OLDER pages, so the displayed last item does not
    /// change there and this never fires on paging.)
    private func maybeScrollToNewItem(_ proxy: ScrollViewProxy, oldLast: String?, newLast: String?, oldCount: Int, newCount: Int) {
        guard didInitialScroll, isAtBottom, feedStartItem == nil, !isSelecting else { return }
        guard newCount > oldCount, let newLast, newLast != oldLast else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(newLast, anchor: .bottom) }
    }

    // MARK: - Loading

    private func fetch(reset: Bool) async {
        guard !isLoading && !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (page, cursor): ([Item], String?)
            switch source {
            case .kind(.recents):
                (page, cursor) = try await viewModel.listAll(
                    limit: 50, cursor: reset ? nil : nextCursor
                )
            case .kind(.favorites):
                (page, cursor) = try await viewModel.listFavorites(
                    limit: 50, cursor: reset ? nil : nextCursor
                )
            case .kind:
                // The other AlbumKind cases are section kinds, never
                // browser sources — unreachable in practice.
                (page, cursor) = ([], nil)
            case .myCollection(let collection):
                (page, cursor) = try await viewModel.listMyCollectionItems(
                    collectionId: collection.id,
                    limit: 50, cursor: reset ? nil : nextCursor
                )
            case .creator(let collection):
                (page, cursor) = try await viewModel.listCollection(
                    authorUsername: collection.id,
                    status: nil,
                    limit: 50, cursor: reset ? nil : nextCursor
                )
            case .media(let media):
                (page, cursor) = try await viewModel.listMedia(
                    media == .video ? "video" : "image",
                    limit: 50, cursor: reset ? nil : nextCursor
                )
            }
            // The /api/list payloads omit is_favorite on the deployed
            // Worker — overlay the flags from the listAll cache.
            items = viewModel.applyingMetadataFavoriteFlags(to: reset ? page : items + page)
            nextCursor = cursor
            // Round-30 (issue 1): My Collection pages arrive in ADDED
            // order (added_at DESC), but the grid sorts by SAVED date
            // and the viewer pages items.reversed() — so viewer and
            // grid disagreed whenever add order differed from save
            // order, and the grid jumped out of order while paging
            // (Library / Recents / Creators all arrive in saved
            // order, so only My Collection was affected). Normalize
            // the page to saved order (newest first) so viewer and
            // grid agree; load-more just re-sorts the accumulated
            // set, the server cursor is untouched.
            if case .myCollection = source {
                items = Array(items.sortedChronologically().reversed())
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadMore() async {
        guard nextCursor != nil, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let (page, cursor): ([Item], String?)
            switch source {
            case .kind(.recents):
                (page, cursor) = try await viewModel.listAll(limit: 50, cursor: nextCursor)
            case .kind(.favorites):
                (page, cursor) = try await viewModel.listFavorites(limit: 50, cursor: nextCursor)
            case .kind:
                (page, cursor) = ([], nil)
            case .myCollection(let collection):
                (page, cursor) = try await viewModel.listMyCollectionItems(
                    collectionId: collection.id, limit: 50, cursor: nextCursor
                )
            case .creator(let collection):
                (page, cursor) = try await viewModel.listCollection(
                    authorUsername: collection.id, status: nil, limit: 50, cursor: nextCursor
                )
            case .media(let media):
                (page, cursor) = try await viewModel.listMedia(
                    media == .video ? "video" : "image", limit: 50, cursor: nextCursor
                )
            }
            // Same is_favorite overlay as fetch().
            items = viewModel.applyingMetadataFavoriteFlags(to: items + page)
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Single-item actions (context menu)

    /// Context menu "Save to Photos": download the item and save it
    /// to the Photos library, with a toast + haptic on success and a
    /// toast with Retry on failure.
    private func saveToPhotos(_ item: Item) {
        Task {
            await viewModel.saveToPhotosWithFeedback(item: item)
        }
    }

    /// Context menu "Share": download the item's file, then open the
    /// iOS share sheet with it.
    private func shareItem(_ item: Item) {
        Task {
            do {
                shareFile = ShareFile(url: try await viewModel.shareFileURL(for: item))
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Context menu "Favorite": toggle the heart and update the local
    /// row in place.
    private func toggleGridFavorite(_ item: Item) {
        Task {
            if let updated = await viewModel.toggleFavorite(item: item),
               let idx = items.firstIndex(where: { $0.id == updated.id }) {
                items[idx] = updated
            }
        }
    }

    /// Context menu "Delete": show the delete confirmation for this
    /// item. (No sheet to dismiss first — the confirmation can
    /// appear immediately.)
    private func requestGridDelete(_ item: Item) {
        itemPendingDelete = item
        showingDeleteConfirmation = true
    }

    /// Delete the item pending confirmation from the grid menu.
    private func deleteGridMenuItem() async {
        guard let target = itemPendingDelete else { return }
        itemPendingDelete = nil
        do {
            try await viewModel.delete(item: target)
            items.removeAll { $0.id == target.id }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Removes an item from this user collection only — the item
    /// itself stays saved in the library.
    private func removeFromCollection(_ item: Item) async {
        guard case .myCollection(let collection) = source else { return }
        do {
            try await viewModel.removeItemFromMyCollection(collectionId: collection.id, item: item)
            items.removeAll { $0.id == item.id }
        } catch {
            removeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteCollection(deleteItems: Bool) async {
        guard case .myCollection(let collection) = source else { return }
        do {
            try await viewModel.deleteMyCollection(id: collection.id, deleteItems: deleteItems)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Rename this album from the "…" menu's Rename Album. The title
    /// updates in place (renamedName); the Albums tab picks up the new
    /// name from the ViewModel's list.
    private func renameCollection() async {
        guard case .myCollection(let collection) = source else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let updated = await viewModel.renameMyCollection(collection, name: name) {
            renamedName = updated.name
        }
    }

    // MARK: - Bulk actions (SelectBottomBar)

    /// Delete every selected item (sequential, reusing the single
    /// delete), then exit multi-select mode. A failure leaves the
    /// item in the grid and is reported.
    private func deleteSelected() async {
        let targets = items.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        var failures = 0
        for item in targets {
            do {
                try await viewModel.delete(item: item)
                items.removeAll { $0.id == item.id }
            } catch {
                failures += 1
            }
        }
        selectedIDs.removeAll()
        isSelecting = false
        if failures > 0 {
            errorMessage = L10n.deletedCountPartial(targets.count - failures, failures)
        }
    }

    private func shareSelection() async {
        let ids = Array(selectedIDs)
        var urls: [URL] = []
        for id in ids {
            guard let item = await resolveItem(id: id) else { continue }
            if let url = try? await viewModel.shareFileURL(for: item) { urls.append(url) }
        }
        guard !urls.isEmpty else {
            viewModel.showToast(L10n.shareDownloadFailed, isError: true)
            return
        }
        shareURLs = urls
        showingBulkShare = true
    }

    private func favoriteSelection() async {
        for id in selectedIDs {
            guard let item = await resolveItem(id: id) else { continue }
            if let updated = await viewModel.toggleFavorite(item: item),
               let idx = items.firstIndex(where: { $0.id == updated.id }) {
                items[idx] = updated
            }
        }
    }

    private func saveSelectionToPhotos() async {
        var saved = 0
        var failed = 0
        for id in selectedIDs {
            guard let item = await resolveItem(id: id) else { failed += 1; continue }
            do {
                try await viewModel.saveToPhotos(item: item)
                saved += 1
            } catch { failed += 1 }
        }
        if failed == 0 {
            viewModel.showToast(L10n.savedToPhotos(saved))
        } else {
            viewModel.showToast(L10n.savedToPhotosPartial(saved, failed), isError: true)
        }
    }
}

/// Add-to-Album sheet for a multi-select (Photos'
/// `AddToAlbumSheet`): pick one user album, add every selected item
/// to it — or create a new album and add them there. (The
/// single-item picker `AddToCollectionPickerView` in PhotoDetailView.swift
/// cannot take a list; the Library tab uses this sheet too (via
/// `onDone`, since step 9).
struct AddToAlbumSheet: View {
    let ids: [String]
    /// Called after adding, with the album name + how many items
    /// were added (nil = just dismiss, as the Albums tab does).
    var onDone: ((String, Int) -> Void)? = nil

    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var name = ""
    @State private var isAdding = false
    @State private var addError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNew = true
                    } label: {
                        Label(L10n.newAlbum, systemImage: "plus")
                    }
                }
                Section(L10n.myAlbums) {
                    if viewModel.myCollections.isEmpty {
                        Text(L10n.noAlbumsYet)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.myCollections) { collection in
                        Button {
                            Task { await addToCollection(collection) }
                        } label: {
                            HStack(spacing: 12) {
                                if let cover = collection.coverItemId {
                                    AspectThumbnail(itemId: cover)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemFill))
                                        .frame(width: 48, height: 48)
                                }
                                VStack(alignment: .leading) {
                                    Text(collection.name)
                                    Text(L10n.collectionVideoCount(collection.count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(isAdding)
                    }
                }
            }
            .navigationTitle(L10n.addToAlbum)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
            }
            .alert(L10n.newAlbum, isPresented: $showNew) {
                TextField(L10n.title, text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.create) {
                    Task { await createAlbumAndAdd() }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.newAlbumMessage)
            }
            .alert("Kepto", isPresented: .constant(addError != nil)) {
                Button("OK") { addError = nil }
            } message: {
                Text(addError ?? "")
            }
            .task {
                await viewModel.fetchMyCollections()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addToCollection(_ collection: MyCollection) async {
        guard !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        var added = 0
        for id in ids {
            guard let item = await resolveItem(id: id) else { continue }
            if await viewModel.addItemToMyCollection(collectionId: collection.id, item: item) == true {
                added += 1
            }
        }
        onDone?(collection.name, added)
        dismiss()
    }

    private func createAlbumAndAdd() async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard let created = await viewModel.createMyCollection(name: title) else { return }
        await addToCollection(created)
    }

    /// The full `Item` for one id: the Library's loaded pages first,
    /// else one fetch by id.
    private func resolveItem(id: String) async -> Item? {
        if let item = viewModel.items.first(where: { $0.id == id }) { return item }
        return await viewModel.fetchItem(id: id)
    }
}

/// Grid columns for album/collection detail grids: 2 columns on
/// narrow screens, 3 on wide ones (spec: "2 hoặc 3 cột tùy kích
/// thước màn hình"). iPhone 12 Pro Max (428pt) gets 3; iPhone SE /
/// 12 (375–390pt) get 2.
private func albumGridColumns() -> [GridItem] {
    let count = UIScreen.main.bounds.width < 400 ? 2 : 3
    return Array(repeating: GridItem(.flexible(), spacing: 2), count: count)
}
