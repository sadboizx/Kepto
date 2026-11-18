import SwiftUI
import UIKit


/// Library: Photos' Library tab, running on Kepto data.
///
/// Structure, layout and gestures follow Photos' `LibraryView`
/// (Photos repo): no title (the bar shows only Select / "…"),
/// Years / Months / Days / All Photos zoom (floating pill + pinch
/// to change level), square grids, multi-select with the
/// Photos-style `SelectBottomBar`, inline toolbar items (never a
/// `toolbarContent` property — the Photos build on 1525ed45 proved
/// the property form does not compile), and a long-press context
/// menu per cell.
///
/// Data comes from `LibraryViewModel`'s full-metadata cache
/// (`allMetadata`, step 1) — sections are complete from the start,
/// never just the loaded pages. Cells render `ItemMetadata` through
/// the step-2 `AssetThumbnail` (`GridItemSource`). The paged
/// `viewModel.items` list is still used where a full `Item` is
/// needed (feed viewer, share, Save to Photos, favorite, delete,
/// Add to Album): the item is resolved from the loaded pages, or
/// fetched by id — and the grid keeps paging ahead as the user
/// scrolls so the resolution is usually already in memory.
///
/// Kepto features kept: the "…" menu (Paste from Clipboard, Photo
/// Library, Choose Files, Settings), the Save-a-link alert, the setup view
/// when unconfigured, and the feed viewer for now (step 7 replaces
/// it with Photos' detail viewer). No `PhotoLibraryService`, no
/// `PHAsset` anywhere in this file.
struct LibraryView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    /// Task Manager store (injected at the app root): the activity
    /// button reads it directly so it appears/disappears as tasks
    /// start and finish.
    @EnvironmentObject private var taskStore: TaskStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    // Round 3: the Library opens on All Photos by default (launch
    // value only — the user can switch, and the choice persists
    // while the app stays alive; it resets to All Photos on the
    // next launch, since this is @State, not persisted).
    @State private var zoom: LibraryZoom = .all
    /// Initial scroll to the bottom (newest, Apple Photos): the
    /// Library opens on the newest photo. `didInitialScroll` marks
    /// the one-time scroll with the full list; `didFallbackScroll`
    /// marks the scroll with only the first page in (the full cache
    /// re-anchors it when it lands — see maybeInitialScroll).
    @State private var didInitialScroll = false
    @State private var didFallbackScroll = false
    /// Round-13: the grid renders only the newest `visibleWindow`
    /// items (a window around the bottom), grown as the user scrolls
    /// up. ScrollViewReader's scrollTo on a lazy grid must lay out
    /// every cell up to its target to compute the offset — scrolling
    /// to the last of the FULL list blocked the main thread for tens
    /// of seconds on open (the 46s "Loading library..." freeze).
    /// With the window, the first scrollTo lays out at most
    /// `visibleWindow` cells. Grown in `growWindowIfNeeded`, pinned
    /// so the viewport does not jump.
    @State private var visibleWindow = 120
    /// The ScrollViewProxy for the pin scrollTo in `growWindowIfNeeded`
    /// (grid cells have no proxy in scope).
    @State private var scrollProxy: ScrollViewProxy?
    /// The ScrollView's global frame (the visible viewport), for the
    /// viewer's onCurrentItemChange: a page whose cell is off-screen
    /// scrolls the grid to it. Updated by onGeometryChange below.
    @State private var scrollViewport: CGRect = .zero
    /// The top chrome height (status bar + nav bar) measured while
    /// the chrome is visible — the ScrollView ignores the top safe
    /// area (see `scroll`) and uses this as a fixed top content
    /// margin instead, so opening/closing the viewer never moves
    /// the grid (round-17 close-jump fix).
    @State private var topChromeHeight: CGFloat = 0
    /// True while the last (newest) cell is on screen — i.e. the
    /// user is at the bottom. Tracked by gridCell's onAppear /
    /// onDisappear; gates the new-item follow scroll and the
    /// cache-landing re-anchor.
    @State private var isAtBottom = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    /// Drag-to-select state (see `DragSelectTracker`): reset on
    /// gesture end and on leaving select mode.
    @State private var dragSelect = DragSelectTracker()
    /// The item the Photos detail viewer opens on (nil = closed).
    @State private var feedStartItem: Item?
    /// The global frame of the thumbnail the viewer opened from
    /// (nil = unknown): the viewer's dismiss drag shrinks the media
    /// onto it on release. Read from `cellFrameCache` at tap time.
    @State private var feedStartFrame: CGRect?
    /// Live cache of grid-cell global frames (see
    /// `CellFrameCache`): written directly by the cells (no
    /// PreferenceKey), read only when a cell is tapped.
    @State private var cellFrameCache = CellFrameCache()
    /// Handle for driving the All Photos UICollectionView (Đợt 2):
    /// scroll-to-bottom on re-tap, scroll-to-current when the viewer
    /// pages. Nil until the collection view is created (zoom == .all);
    /// stays populated across state changes, cleared when All Photos
    /// is torn down (zoom switches away).
    @State private var gridScroll = GridScrollController()
    /// Items resolved for the slideshow (empty = closed).
    @State private var slideshowItems: [Item] = []
    @State private var showingSlideshow = false
    /// The video the context menu's "Add to Album" opened the picker
    /// for (nil = picker closed).
    @State private var itemForAlbumPicker: Item?
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// Downloaded files for a bulk share (nil = closed).
    @State private var shareURLs: [URL]?
    @State private var showingBulkShare = false
    /// Items resolved for the bulk Add-to-Album sheet.
    @State private var addToAlbumItems: [Item] = []
    @State private var showingAddToAlbum = false
    /// Ids awaiting delete confirmation (one item or the selection).
    @State private var pendingDelete: [String] = []
    @State private var showDelete = false
    @State private var showingSettings = false
    /// URL-input alert (shown by the empty-state "Save a link" button).
    @State private var showingURLInput = false
    @State private var urlInput = ""
    /// Activity (Task Manager) sheet.
    @State private var showingActivity = false

    /// Round-31: re-tap counter from the tab bar (KeptoTabView
    /// bumps it when the already-selected Library tab is tapped).
    @Binding var retapRequest: Int

    init(retapRequest: Binding<Int> = .constant(0)) {
        _retapRequest = retapRequest
    }

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.isConfigured {
                    setupView
                } else if viewModel.isLoading && viewModel.items.isEmpty && viewModel.allMetadata.isEmpty {
                    // Round-27: cold cache (first-ever launch) shows
                    // the grid layout with gray placeholder cells —
                    // never a full-screen spinner. Same columns as
                    // the All Photos grid, so the real cells land
                    // without a layout flash. The floating zoom pill
                    // is part of `scroll`, so it appears with it.
                    ScrollView {
                        LazyVGrid(columns: fixedColumns(count: sizeClass == .regular ? 8 : 4, width: scrollViewport.width), spacing: 2) {
                            ForEach(0..<12, id: \.self) { _ in
                                Color(.systemGray5)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                } else if viewModel.items.isEmpty && viewModel.allMetadata.isEmpty {
                    emptyView
                } else {
                    scroll
                }
            }
            // No "Library" title (user request): the bar shows only
            // the trailing Select / "…" buttons. In select mode the
            // count ("N Selected") still shows, centred inline.
            .navigationTitle(selecting ? L10n.selectedCount(selection.count) : "")
            .navigationBarTitleDisplayMode(.inline)
            // Transparent status bar / nav bar (Photos): the grid
            // shows through under the status bar and the bar, no
            // solid band — same as the Albums tab.
            .toolbarBackground(.hidden, for: .navigationBar)
            // While the viewer overlay is open, hide the navigation
            // bar and the status bar: the viewer's own
            // .statusBarHidden does not take effect inside an
            // overlay in a NavigationStack, so it has to be set
            // here, on the opener's root. Both return the moment
            // the viewer closes (feedStartItem = nil). The grid
            // does not move either way: the ScrollView ignores the
            // top safe area and uses a fixed top margin (see
            // `scroll` + `topChromeHeight`) — before round-17 the
            // inset change landed ~0.25s after the chrome and the
            // grid visibly slid down ~45pt on close.
            .toolbar(feedStartItem == nil ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(feedStartItem != nil)
            // Measure the top chrome height while it is visible
            // (status bar + nav bar); latched at its max so the
            // ScrollView's fixed top margin stays put when the
            // viewer hides the chrome (round-17 close-jump fix).
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { newTop in
                if newTop > topChromeHeight { topChromeHeight = newTop }
            }
            // Round-31: re-tap on the Library tab — scroll to the
            // bottom (newest). scrollToBottomAnimated guards
            // itself (already at bottom / viewer open / empty).
            .onChange(of: retapRequest) { _, _ in scrollToBottomAnimated() }
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { exitSelection() } label: {
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
                    // No Select All here: it applies to albums,
                    // not to Library / Recents (Photos has none
                    // there either) — only Cancel.
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            // Task Manager: visible only while a task
                            // is running, waiting for network, or
                            // failed. The bolt spins subtly while
                            // anything runs; the cloud-slash marks a
                            // network wait.
                            if taskStore.hasVisibleTasks {
                                Button {
                                    Haptics.tap()
                                    showingActivity = true
                                } label: {
                                    Image(systemName: taskStore.isAnyWaiting ? "icloud.slash" : "bolt")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(.regularMaterial, in: Capsule())
                                        .rotationEffect(taskStore.isAnyRunning ? .degrees(360) : .degrees(0))
                                        .animation(taskStore.isAnyRunning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: taskStore.isAnyRunning)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.activity)
                            }
                            Button {
                                Haptics.tap()
                                selecting = true
                            } label: {
                                Text(L10n.select)
                                    .font(.footnote)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(allIDs.isEmpty)
                            Menu {
                                Button { Task { await saveDirectFromClipboard() } } label: {
                                    Label(L10n.pasteClipboard, systemImage: "doc.on.clipboard")
                                }
                                Button { viewModel.showingPhotoPicker = true } label: {
                                    Label(L10n.photoLibrary, systemImage: "photo.on.rectangle")
                                }
                                Button { viewModel.showingDocumentPicker = true } label: {
                                    Label(L10n.chooseFiles, systemImage: "folder")
                                }
                                Button { showingSettings = true } label: {
                                    Label(L10n.settings, systemImage: "gearshape")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                                    .accessibilityLabel(L10n.moreOptions)
                            }
                        }
                    }
                }
            }
            .toolbar(selecting ? .hidden : .visible, for: .tabBar)
            // The Years / Months / Days / All Photos pill is a
            // floating overlay (below), not a safe-area inset — only
            // the select bar reserves bottom space, in select mode.
            // (v60 did the same: the pill floated over the grid, and
            // the grids' last row cleared it via a bottom content
            // margin on the scroll view.)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting {
                    selectBar
                }
            }
            // Floating view-mode pill above the tab bar (v60 style).
            .overlay(alignment: .bottom) {
                if !selecting, viewModel.isConfigured {
                    ZoomSegmentBar(zoom: $zoom, onRetap: { _ in scrollToBottomAnimated() })
                        .padding(.bottom, 8)
                }
            }
            .refreshable {
                await viewModel.fetch()
            }
            .task {
                await viewModel.fetch()
                await viewModel.fetchStats()
                // If anything is still ingesting, poll until its
                // thumbnail is ready (no tab switch needed).
                viewModel.startPendingPoll()
            }
            .alert(L10n.saveLinkAlert, isPresented: $showingURLInput) {
                TextField(
                    L10n.pasteLinkPlaceholder,
                    text: $urlInput
                )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(L10n.save) {
                    let url = urlInput
                    urlInput = ""
                    Task { await saveDirect(url) }
                }
                Button(L10n.cancel, role: .cancel) { urlInput = "" }
            }
            // The viewer is a full-screen OVERLAY over this grid
            // (not a NavigationStack push): the grid stays in the
            // same hierarchy underneath, so it genuinely shows
            // through when the black background fades during a
            // drag-down-to-dismiss — a push cannot do that (its
            // hosting layer is opaque, so the fade only ever
            // revealed black, and the pop slid a black bar across
            // the screen). Closing just clears feedStartItem.
            .overlay {
                if let startItem = feedStartItem {
                    PhotoDetailView(
                        items: Binding(get: { viewModel.items }, set: { _ in }),
                        startItemId: startItem.id,
                        onNearEnd: { await viewModel.loadMore() },
                        title: L10n.library,
                        sourceFrame: feedStartFrame,
                        onDismiss: { feedStartItem = nil },
                        // Live frame lookup for the close (round-9):
                        // the viewer re-queries the cell's frame at
                        // release instead of trusting the tap-time
                        // capture.
                        frameLookup: { [cellFrameCache] id in cellFrameCache.frames[id] },
                        // Apple Photos keeps the grid under the
                        // viewer on the current item: if the cell is
                        // off-screen, scroll the grid to it instantly
                        // (no animation — the grid is hidden behind
                        // the viewer, so the move is invisible); if
                        // it is already fully visible, do nothing.
                        onCurrentItemChange: { [cellFrameCache] id in
                            // All Photos: collection view scroll (native).
                            // Days/Months/Years: ScrollViewProxy scroll.
                            if zoom == .all {
                                if let frame = cellFrameCache.frames[id],
                                   scrollViewport.insetBy(dx: 0, dy: 8).contains(frame) { return }
                                gridScroll.scrollTo(id: id, at: .centeredVertically, animated: false)
                                return
                            }
                            guard let frame = cellFrameCache.frames[id],
                                  let proxy = scrollProxy else { return }
                            let visible = scrollViewport.insetBy(dx: 0, dy: 8)
                            guard !visible.contains(frame) else { return }
                            var transaction = Transaction()
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
                        }
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            viewModel.reloadConfig()
            Task { await viewModel.fetch() }
        }) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showingSlideshow) {
            SlideshowView(items: slideshowItems)
        }
        .sheet(item: $itemForAlbumPicker) { pickerItem in
            AddToCollectionPickerView(
                item: pickerItem,
                onAddedToCollection: { name, added in
                    viewModel.showToast(added ? L10n.addedToCollection(name) : L10n.alreadyInCollection(name))
                },
                onCancel: { itemForAlbumPicker = nil }
            )
        }
        .sheet(isPresented: $showingAddToAlbum) {
            AddToAlbumSheet(
                ids: addToAlbumItems.map(\.id),
                onDone: { name, added in
                    viewModel.showToast(L10n.addedCountToCollection(added, name))
                    exitSelection()
                }
            )
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(activityItems: [file.url])
        }
        .sheet(isPresented: $showingBulkShare) {
            ShareSheet(activityItems: shareURLs ?? [])
        }
        .confirmationDialog(deleteDialogTitle, isPresented: $showDelete, titleVisibility: .visible) {
            Button(L10n.delete, role: .destructive) {
                let ids = pendingDelete
                Task { await deleteItems(ids) }
            }
            Button(L10n.cancel, role: .cancel) { pendingDelete = [] }
        } message: {
            Text(L10n.deleteFromCloudMessage)
        }
        .alert("Kepto", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showingActivity) {
            ActivitySheet()
        }
        .onChange(of: zoom) { _, _ in
            Haptics.select()
            // Round-18: switching mode does NOT scroll — the grid
            // re-renders in the new zoom as before. Scroll-to-bottom
            // happens only on a re-tap of the active segment, via
            // ZoomSegmentBar's onRetap (scrollToBottomAnimated).
            //
            // Đợt 2: All Photos (UICollectionView) and Days (LazyVGrid)
            // track isAtBottom independently — reset on zoom switch so
            // a Days-"at-bottom" flag cannot leak into an All-Photos
            // maybeScrollToNewItem (and vice versa). The other grid
            // sets its own flag on the next cell visibility change.
            // The ScrollViewProxy is only valid for the ScrollView
            // zooms — nil it out when entering .all so a stale proxy
            // is never used there.
            isAtBottom = false
            // Đợt 2 fix: reset the window — Days/Months render only
            // the newest `visibleWindow` items, so a grown window
            // from another zoom must not leak across.
            visibleWindow = 120
            if zoom == .all { scrollProxy = nil }
        }
    }

    private var setupView: some View {
        ContentUnavailableView {
            Label(L10n.setupKepto, systemImage: "link.badge.plus")
        } description: {
            Text(L10n.setupHint)
        } actions: {
            Button(L10n.openSettings) { showingSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label(L10n.nothingSavedYet, systemImage: "tray")
        } description: {
            Text(L10n.emptyLibraryHint)
        } actions: {
            Button(L10n.saveLink) { showingURLInput = true }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Fixed-width columns (hot-path fix): `.flexible()` re-measures
    /// every layout pass and rounds sub-pixel widths differently per
    /// row, causing 0.5px jitter while scrolling. `.fixed(floor(...))`
    /// makes every cell an integer-pixel width. While the viewport is
    /// still zero (first layout, before `.onGeometryChange` fires)
    /// fall back to `.flexible()`. Column counts unchanged.
    private func fixedColumns(count: Int, width: CGFloat) -> [GridItem] {
        guard width > 0 else {
            return Array(repeating: GridItem(.flexible(), spacing: 2), count: count)
        }
        let itemWidth = floor((width - 2 * CGFloat(count - 1)) / CGFloat(count))
        return Array(repeating: GridItem(.fixed(itemWidth), spacing: 2), count: count)
    }

    private var dayColumns: [GridItem] {
        // Fallback to screen width while scrollViewport is still
        // zero (first layout, or right after switching zooms before
        // .onGeometryChange fires) — same pattern as allCellWidth.
        let width = scrollViewport.width > 0 ? scrollViewport.width : UIScreen.main.bounds.width
        return fixedColumns(count: sizeClass == .regular ? 5 : 3, width: width)
    }

    /// Cell width for the All Photos UICollectionView (Đợt 2): same
    /// formula as fixedColumns — integer-pixel, 4/8 columns, spacing
    /// 2. Falls back to screen width before the first layout pass
    /// (scrollViewport == .zero) so cells are the right size on the
    /// very first apply, no flash on the first data landing.
    private var allCellWidth: CGFloat {
        let count = sizeClass == .regular ? 8 : 4
        let spacing: CGFloat = 2
        let totalSpacing = spacing * CGFloat(count - 1)
        let width = scrollViewport.width > 0 ? scrollViewport.width : UIScreen.main.bounds.width
        return floor((width - totalSpacing) / CGFloat(count))
    }

    private var scroll: some View {
        Group {
            if zoom == .all {
                // All Photos is UICollectionView-backed now (Đợt 2):
                // the collection view IS the scroller, so it renders
                // top-level here — never inside the ScrollView below
                // (a UICollectionView has no intrinsic content size
                // and lays out at height 0 inside a vertical
                // ScrollView, and the two vertical scrollers would
                // fight). Same chrome as the ScrollView branch: the
                // view ignores the top safe area; the top inset is
                // applied by the collection view itself (topInset).
                allPhotosGrid
                    .background(Color(uiColor: .systemBackground))
                    .ignoresSafeArea(.container, edges: .top)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { scrollViewport = $0 }
                    .simultaneousGesture(pinch)
                    .onAppear {
                        // No ScrollViewProxy exists for the collection
                        // view — the .all scroll helpers take nil.
                        scrollProxy = nil
                        maybeInitialScroll(nil)
                    }
                    .onChange(of: viewModel.cachedAllIDs) { oldIDs, newIDs in
                        maybeInitialScroll(nil)
                        maybeScrollToNewItem(nil, oldIDs: oldIDs, newIDs: newIDs)
                    }
                    .onChange(of: viewModel.allMetadataLoaded) { _, _ in
                        maybeInitialScroll(nil)
                    }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        switch zoom {
                        case .years:
                            yearsGrid
                        case .months:
                            monthsGrid
                        case .days:
                            daysGrid
                        case .all:
                            // Unreachable: .all renders top-level
                            // above. Kept for exhaustiveness.
                            EmptyView()
                        }
                    }
                    // The ScrollView ignores the top safe area: its top
                    // inset is always 0, so hiding/showing the nav bar +
                    // status bar for the viewer never changes it — the grid
                    // cannot jump on close (round-17: the inset change used
                    // to land ~0.25s after the chrome, sliding the grid down
                    // ~45pt). The fixed top margin below replaces the inset,
                    // so the top looks exactly as before. Bottom margin so
                    // the last row scrolls clear of the floating
                    // Years/Months/Days/All Photos pill.
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
                    // grows upward); pull-to-refresh only swaps the page in
                    // place, so it does not reset the position — and a
                    // mid-list user is not yanked when items append below
                    // the viewport. One anchor covers the three zooms that
                    // share this ScrollView (Years / Months / Days).
                    .defaultScrollAnchor(.bottom)
                    .ignoresSafeArea(.container, edges: .top)
                    // (EdgeInsets form of contentMargins is iOS 18+ — the
                    // project targets iOS 17.4, so top/bottom use the
                    // separate Edge.Set calls that exist since iOS 17.)
                    .contentMargins(.top, topChromeHeight, for: .scrollContent)
                    .contentMargins(.bottom, 64, for: .scrollContent)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { scrollViewport = $0 }
                    .background(Color(uiColor: .systemBackground))
                    .simultaneousGesture(pinch)
                    .simultaneousGesture(dragSelectGesture)
                    .onAppear {
                        scrollProxy = proxy
                        maybeInitialScroll(proxy)
                    }
                    .onChange(of: viewModel.cachedAllIDs) { oldIDs, newIDs in
                        maybeInitialScroll(proxy)
                        maybeScrollToNewItem(proxy, oldIDs: oldIDs, newIDs: newIDs)
                    }
                    .onChange(of: viewModel.allMetadataLoaded) { _, _ in
                        maybeInitialScroll(proxy)
                    }
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: zoom)
    }

    private var yearsGrid: some View {
        LazyVStack(spacing: 16) {
            ForEach(years) { year in
                Button {
                    Haptics.tap()
                    zoom = .months
                } label: {
                    yearCard(year)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
    }

    private func yearCard(_ year: YearSection) -> some View {
        ZStack(alignment: .bottomLeading) {
            mosaic(ids: year.coverIDs)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(year.title)
                    .font(.system(size: 34, weight: .bold, design: .default))
                Text(itemCountText(year.itemIDs.count))
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .padding(16)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 14)
    }

    private func mosaic(ids: [String]) -> some View {
        let cells = Array(ids.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(0..<4, id: \.self) { index in
                if index < cells.count, let source = source(for: cells[index]) {
                    AssetThumbnail(source: source)
                } else {
                    Color(uiColor: .secondarySystemFill)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
    }

    private var monthsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(months) { month in
                Button {
                    Haptics.tap()
                    zoom = .days
                } label: {
                    monthCard(month)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    private func monthCard(_ month: MonthSection) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let cover = month.coverID, let source = source(for: cover) {
                AssetThumbnail(source: source, cornerRadius: 12, showFavoriteMark: false)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
            }
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(month.title)
                    .font(.headline)
                Text(itemCountText(month.itemIDs.count))
                    .font(.caption)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .aspectRatio(1.05, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var daysGrid: some View {
        // DEBUG — xoá sau khi xác định nguyên nhân.
        let _ = print("[Days] windowedDays=\(windowedDays.count) days=\(days.count) cachedDayGroups=\(viewModel.cachedDayGroups.count) items=\(viewModel.items.count) allMetadata=\(viewModel.allMetadata.count) allMetadataLoaded=\(viewModel.allMetadataLoaded) scrollViewport=\(scrollViewport) dayColumns=\(dayColumns)")
        return VStack(spacing: 0) {
            if windowedDays.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label(L10n.nothingSavedYet, systemImage: "tray")
                } description: {
                    Text(L10n.emptyLibraryHint)
                }
                .frame(maxHeight: .infinity)
            } else {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(windowedDays) { day in
                        Section {
                            LazyVGrid(columns: dayColumns, spacing: 2) {
                                ForEach(day.itemIDs, id: \.self) { id in
                                    gridCell(for: id)
                                }
                            }
                        } header: {
                            DayHeader(title: day.title, subtitle: day.subtitle)
                        }
                    }
                }
            }
        }
    }

    /// All Photos grid on UICollectionView (Đợt 2): native virtualization
    /// + prefetching + Apple Photos-exact scroll APIs. The collection
    /// view renders the FULL allIDs (no `visibleWindow` cap) — the
    /// UIKit side virtualizes 10k+ items without a pin hack. Cell
    /// taps, context menus and the drag-to-select tracker are wired
    /// through the representable's closures (same behavior as before).
    private var allPhotosGrid: some View {
        PhotoGridCollectionView(
            ids: allIDs,
            selecting: selecting,
            selectedIDs: selection,
            cellWidth: allCellWidth,
            spacing: 2,
            topInset: topChromeHeight,
            columnCount: sizeClass == .regular ? 8 : 4,
            frameCache: cellFrameCache,
            scrollController: gridScroll,
            viewModel: viewModel,
            sourceFor: { source(for: $0) },
            contextMenuFor: { id in
                guard let source = source(for: id) else { return AnyView(EmptyView()) }
                return AnyView(cellMenu(for: source))
            },
            onTap: { handleTap($0) },
            onPrefetch: { ids in viewModel.prefetchMissingThumbnails(ids: ids) },
            onDragSelect: { selection = $0 },
            onWillDisplayNearTop: { index in maybeLoadMore(at: index) },
            onLastCellVisibilityChange: { visible in isAtBottom = visible }
        )
    }

    /// The newest day groups whose items total at least the window
    /// (at least one group): the Days grid renders only these, so
    /// its initial scrollTo stays bounded like All Photos.
    private var windowedDays: [DaySection] {
        var kept: [DaySection] = []
        var count = 0
        for day in days.reversed() {
            kept.append(day)
            count += day.itemIDs.count
            if count >= visibleWindow { break }
        }
        return kept.reversed()
    }

    private func gridCell(for id: String) -> some View {
        Group {
            if let source = source(for: id) {
                AssetThumbnail(source: source, selecting: selecting, selected: selection.contains(id))
                    .onTapGesture { handleTap(id) }
                    .contextMenu { cellMenu(for: source) }
            } else {
                Color(uiColor: .secondarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        // Report this cell's global frame for the viewer's
        // shrink-to-thumbnail dismiss: written straight into the
        // cache (no PreferenceKey — preference propagation on every
        // scroll frame was a top drop-frame source). The frame is
        // read from the cache at tap time, so the viewer knows where
        // its media must land on release.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cellFrameCache.set(id, geo.frame(in: .global)) }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        cellFrameCache.set(id, newFrame)
                    }
            }
        )
        .onAppear {
            if id == allIDs.last { isAtBottom = true }
            if let index = viewModel.cachedIndexById[id] {
                maybeLoadMore(at: index)
                growWindowIfNeeded(at: index, id: id)
            }
        }
        .onDisappear {
            if id == allIDs.last { isAtBottom = false }
        }
    }

    /// Native iOS context menu for a grid cell (long-press), in the
    /// order the user asked for: Share, Save to Photos, Favorite,
    /// Add to Album, Delete. Inline here (not `GridItemContextMenu`):
    /// Library cells are light `ItemMetadata`, and the menu actions
    /// resolve the full `Item` on demand — the shared menu takes an
    /// `Item` at construction and belongs to the paged grids
    /// (PhotoCollectionScreen keeps using it). Empty while
    /// multi-select is on (a tap toggles selection instead).
    private func cellMenu(for source: any GridItemSource) -> some View {
        Group {
            // No menu on an upload placeholder (no real item to
            // share, save, favorite, or delete yet).
            if !selecting, !viewModel.isUploadPlaceholder(source.id) {
                Button { Task { await shareItem(source.id) } } label: {
                    Label(L10n.share, systemImage: "square.and.arrow.up")
                }
                Button { Task { await saveToPhotos(source.id) } } label: {
                    Label(L10n.saveToPhotos, systemImage: "arrow.down.to.line")
                }
                Button { Task { await toggleFavorite(source.id) } } label: {
                    Label(L10n.favorite, systemImage: source.isFavorite ? "heart.fill" : "heart")
                }
                Button { Task { await openAddToAlbum(source.id) } } label: {
                    Label(L10n.addToAlbum, systemImage: "rectangle.stack.badge.plus")
                }
                Button(role: .destructive) {
                    pendingDelete = [source.id]
                    showDelete = true
                } label: {
                    Label(L10n.delete, systemImage: "trash")
                }
            }
        }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onEnded { value in
                guard !selecting else { return }
                if value > 1.12 {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        zoom = zoom.zoomedIn()
                    }
                } else if value < 0.9 {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        zoom = zoom.zoomedOut()
                    }
                }
            }
    }

    // MARK: - Sections (from the full-metadata cache)

    /// All ids in the Library, oldest first (Apple Photos). The full
    /// metadata cache when it is loaded; the loaded pages while listAll
    /// is still pending or failed (so the Library never goes blank when
    /// the metadata fetch has not finished yet).
    /// All ids in the Library, oldest first (Apple Photos). Round-13:
    /// a stored cache in the view model, rebuilt once when the source
    /// changes — this used to re-sort the whole cache on every access,
    /// which is what saturated the main thread while scrolling.
    private var allIDs: [String] { viewModel.cachedAllIDs }

    /// The thumbnail source for one id: light metadata first, the
    /// loaded full `Item` as fallback (while the metadata cache is
    /// still loading). Both lookups are cached O(1) now — the old
    /// code rebuilt the whole metadata dictionary per cell render
    /// and scanned the loaded pages per cell.
    private func source(for id: String) -> (any GridItemSource)? {
        if let meta = viewModel.cachedMetadataById[id] { return meta }
        return viewModel.cachedItemsById[id]
    }

    private var days: [DaySection] {
        viewModel.cachedDayGroups.map { group in
            DaySection(id: Self.dayIDFormatter.string(from: group.key), date: group.key, title: DateLabels.dayTitle(for: group.key), subtitle: nil, itemIDs: group.ids)
        }
    }

    private var months: [MonthSection] {
        viewModel.cachedMonthGroups.map { group in
            MonthSection(id: Self.monthIDFormatter.string(from: group.key), date: group.key, title: DateLabels.monthTitle(for: group.key), itemIDs: group.ids, coverID: group.ids.last)
        }
    }

    private var years: [YearSection] {
        viewModel.cachedYearGroups.map { group in
            let year = Calendar.current.component(.year, from: group.key)
            return YearSection(year: year, title: String(year), itemIDs: group.ids, coverIDs: Array(group.ids.suffix(4)))
        }
    }

    private static let dayIDFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthIDFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private func itemCountText(_ count: Int) -> String {
        L10n.itemsCount(count)
    }

    // MARK: - Paging ahead

    /// Keep the paged `items` list ahead of what the user can see:
    /// the grid renders the full metadata cache, but the feed viewer
    /// and the item actions need full `Item`s, which only arrive
    /// page by page. The loaded full Items are the NEWEST ones: in
    /// the ascending allIDs they sit at the END, so the oldest loaded
    /// item is at index (allIDs.count - items.count). Page ahead when
    /// a cell appears within 10 of that boundary (the user scrolling
    /// up into not-yet-loaded older items).
    private func maybeLoadMore(at index: Int) {
        guard viewModel.hasMore, !viewModel.items.isEmpty else { return }
        guard index <= viewModel.cachedOldestLoadedIndex + 10 else { return }
        Task { await viewModel.loadMore() }
    }

    /// Grow the rendered window as the user scrolls up into older
    /// items (round-13 perf — see `visibleWindow`). Fires when a
    /// cell appears within 10 of the window's oldest end. Prepending
    /// cells above the viewport would shift the visible content down
    /// by the inserted height, so the appearing cell is pinned back
    /// to the top edge on the next runloop (after the new cells are
    /// laid out) — the viewport does not jump. The pin lays out at
    /// most one growth chunk of new cells.
    private func growWindowIfNeeded(at index: Int, id: String) {
        // All Photos is UICollectionView-backed now (Đợt 2) — it
        // virtualizes its full list with no window cap. This method
        // is only reached from gridCell (Days), so the "windowed"
        // growth applies to Days only. The cache prune keeps only
        // Days frames.
        guard zoom == .days else { return }
        let windowTop = max(allIDs.count - visibleWindow, 0)
        guard windowTop > 0, index <= windowTop + 10 else { return }
        guard let proxy = scrollProxy else { return }
        visibleWindow += 120
        // Prune stale cell frames: only Days cells write via gridCell
        // (All Photos cells write via the collection view's
        // willDisplay and are pruned by the collection view's own
        // lifecycle — a stale entry is harmless, never read).
        cellFrameCache.prune(keeping: Set(windowedDays.flatMap(\.itemIDs)))
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    // MARK: - Scroll to bottom (Apple Photos order)

    /// The id to scroll to for "the bottom" (newest) in the current
    /// zoom: the last cell in All Photos / Days, the last card in
    /// Months / Years.
    /// The id to scroll to for "the bottom" on the ScrollView-backed
    /// zooms (Days / Months / Years). All Photos uses the collection
    /// view's own scrollToItem (see scrollToBottomAnimated / Instant).
    private var scrollTargetID: String? {
        switch zoom {
        case .all: nil
        case .days: windowedDays.last?.itemIDs.last
        case .months: months.last?.id
        case .years: years.last?.id
        }
    }

    /// Instant (no-animation) scroll to the bottom. The transaction
    /// disables animations outright — a plain scrollTo inside the
    /// zoom-animated ScrollView could otherwise visibly slide down.
    private func scrollToBottomInstant(_ proxy: ScrollViewProxy?) {
        if zoom == .all {
            // The collection view handles its own initial scroll
            // (see PhotoGridCollectionView.Coordinator's
            // performInitialScrollIfNeeded). Calling gridScroll here
            // would race the first data apply — no-op when the
            // collection view is not populated yet, which is fine
            // (it will scroll itself once populated).
            gridScroll.scrollToBottom(animated: false)
            return
        }
        guard let proxy = proxy, let id = scrollTargetID else { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: .bottom) }
    }

    /// Animated scroll to the bottom (newest) for a re-tap on the
    /// already-selected zoom pill (round-18, Apple Photos pattern):
    /// same zoom-aware target as the instant scroll, but eased over
    /// ~0.4s instead of teleporting. No-ops when already at the
    /// bottom (isAtBottom), when the list is empty (no target), or
    /// while the viewer is open. No data reload — only the scroll.
    /// Rapid re-taps are harmless: every tap targets the same last
    /// id, so a new animation just retargets the same destination
    /// instead of stacking.
    private func scrollToBottomAnimated() {
        guard !isAtBottom, feedStartItem == nil else { return }
        if zoom == .all {
            // Apple Photos-parity scroll: UICollectionView's
            // scrollToItem is a single animated pass, no
            // ScrollViewProxy layout hop.
            gridScroll.scrollToBottom(animated: true)
        } else if let proxy = scrollProxy, let id = scrollTargetID {
            withAnimation(.easeOut(duration: 0.4)) { proxy.scrollTo(id, anchor: .bottom) }
        }
    }

    /// Scroll to the bottom (newest) once, instantly, on first open
    /// (Apple Photos opens on the newest photo). Fires when the full
    /// metadata cache is loaded; if only the first page is in so far,
    /// scrolls to the bottom of that page and re-anchors when the
    /// cache lands — but only while the user is still at the bottom
    /// (isAtBottom), so a user who already scrolled up is never
    /// yanked back. Never fires while the viewer is open, and never
    /// on pull-to-refresh / delete (those leave allIDs unchanged or
    /// shrink it, and the once-flag is already set). The target is
    /// the last of the windowed list (see `scrollTargetID`), so the
    /// scrollTo lays out at most one window of cells.
    private func maybeInitialScroll(_ proxy: ScrollViewProxy?) {
        guard !didInitialScroll, !allIDs.isEmpty, feedStartItem == nil else { return }
        if zoom == .all {
            // All Photos: the collection view scrolls itself to the
            // bottom once its data source is populated (see
            // PhotoGridCollectionView.Coordinator). Mark the flag so
            // maybeScrollToNewItem starts firing; the actual scroll
            // is the collection view's job.
            if viewModel.allMetadataLoaded { didInitialScroll = true }
            return
        }
        if viewModel.allMetadataLoaded {
            // Re-anchoring after a fallback scroll: only if the user
            // is still at the bottom — the full list grew above them
            // when the cache landed, and a user who moved off the
            // bottom must not be yanked back.
            if didFallbackScroll && !isAtBottom { didInitialScroll = true; return }
            scrollToBottomInstant(proxy)
            didInitialScroll = true
        } else if !didFallbackScroll {
            scrollToBottomInstant(proxy)
            didFallbackScroll = true
        }
    }

    /// A new item arrived at the end (bottom): if the user is at the
    /// bottom, follow it down smoothly; if they are mid-list, leave
    /// their scroll position alone (the item waits at the bottom).
    /// EXCEPTION — a just-imported item: the user added it on purpose
    /// and expects to see it, so the Library jumps to it even from
    /// mid-list (and even though the import sheet was open when it
    /// landed). Only after the initial scroll — and never while the
    /// viewer or select mode is open.
    private func maybeScrollToNewItem(_ proxy: ScrollViewProxy?, oldIDs: [String], newIDs: [String]) {
        guard (didInitialScroll || didFallbackScroll), feedStartItem == nil, !selecting else { return }
        guard zoom == .all || zoom == .days else { return }
        guard newIDs.count > oldIDs.count, let newLast = newIDs.last, newLast != oldIDs.last else { return }
        let isFreshImport = viewModel.justImportedIDs.contains(newLast)
        guard isAtBottom || isFreshImport else { return }
        if zoom == .all {
            // UICollectionView: data source apply is animated by the
            // diff (insert of the new last item); scrollToItem lands
            // the user on it. Simpler than a ScrollViewProxy scroll
            // because the target cell already exists (data source
            // applied before this onChange handler runs).
            gridScroll.scrollTo(id: newLast, at: .bottom, animated: true)
        } else if let proxy = proxy {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(newLast, anchor: .bottom) }
        }
        if isFreshImport { viewModel.clearJustImportedIDs() }
    }

    // MARK: - Multi-select

    /// (photos, videos, unknown) among the selection, for the
    /// bottom bar's center text. The grid pages, so an id past the
    /// loaded pages has an unknown kind — and any unknown forces
    /// the "Items" wording (see `L10n.selectionSummary`).
    private var selectionKindCounts: (photos: Int, videos: Int, unknown: Int) {
        var byID: [String: Item] = [:]
        for item in viewModel.items { byID[item.id] = item }
        var photos = 0, videos = 0, unknown = 0
        for id in selection {
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

    private var selectBar: some View {
        SelectBottomBar(
            photoCount: selectionKindCounts.photos,
            videoCount: selectionKindCounts.videos,
            unknownCount: selectionKindCounts.unknown,
            onShare: { Task { await shareSelection() } },
            onDelete: {
                pendingDelete = Array(selection)
                showDelete = true
            }
        ) {
            Menu {
                Button { Task { await saveSelectionToPhotos() } } label: {
                    Label(L10n.saveToPhotos, systemImage: "arrow.down.to.line")
                }
                Button { Task { await presentAddToAlbum() } } label: {
                    Label(L10n.addToAlbum, systemImage: "rectangle.stack.badge.plus")
                }
                Button { Task { await favoriteSelection() } } label: {
                    Label(L10n.favorite, systemImage: "heart")
                }
                Button { Task { await presentSlideshow() } } label: {
                    Label(L10n.slideshow, systemImage: "play.rectangle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
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
                // Đợt 2: never runs for All Photos — the collection
                // view's own UIPanGestureRecognizer owns drag-select
                // there (two independent DragSelectTrackers would
                // pin conflicting modes). The .all branch of `scroll`
                // does not attach this gesture at all; this guard is
                // belt-and-braces.
                guard selecting, zoom != .all else { return }
                selection = dragSelect.update(
                    start: value.startLocation,
                    current: value.location,
                    toGlobal: { CGPoint(x: scrollViewport.origin.x + $0.x, y: scrollViewport.origin.y + $0.y) },
                    frames: cellFrameCache.frames,
                    selection: selection
                )
            }
            .onEnded { _ in dragSelect.reset() }
    }

    private func exitSelection() {
        selecting = false
        selection.removeAll()
        dragSelect.reset()
    }

    private func handleTap(_ id: String) {
        // Upload placeholders are not real items yet — no viewer,
        // no selection. A tap just says it is still uploading.
        if viewModel.isUploadPlaceholder(id) {
            if !selecting { viewModel.showToast(L10n.uploadingPleaseWait) }
            return
        }
        if selecting {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            Haptics.select()
        } else {
            // Capture the tapped cell's frame before opening: the
            // viewer's dismiss drag shrinks the media onto it.
            feedStartFrame = cellFrameCache.frames[id]
            openItem(id)
        }
    }

    /// Open the feed on one item. The feed pages through the loaded
    /// `items` list, so an item past the loaded pages is pulled in
    /// first (usually it already is — `maybeLoadMore` pages ahead
    /// while scrolling). Bounded: stops when a load adds nothing
    /// (a fetch is already in flight) or the pages run out.
    private func openItem(_ id: String) {
        if let item = viewModel.items.first(where: { $0.id == id }) {
            feedStartItem = item
            return
        }
        Task {
            var lastCount = viewModel.items.count
            for _ in 0..<10 {
                if viewModel.items.first(where: { $0.id == id }) != nil { break }
                guard viewModel.hasMore else { break }
                await viewModel.loadMore()
                let count = viewModel.items.count
                if count == lastCount { break }
                lastCount = count
            }
            if let item = viewModel.items.first(where: { $0.id == id }) {
                feedStartItem = item
            }
        }
    }

    /// The full `Item` for one id: the loaded pages first, else one
    /// fetch by id. Used by every action that needs more than the
    /// light metadata (share, Save to Photos, favorite, delete,
    /// Add to Album).
    private func resolveItem(id: String) async -> Item? {
        if let item = viewModel.items.first(where: { $0.id == id }) { return item }
        return await viewModel.fetchItem(id: id)
    }

    /// Start the slideshow over the current selection, in grid order
    /// (Photos: the slideshow runs over the selected items).
    private func presentSlideshow() async {
        let ids = allIDs.filter { selection.contains($0) }
        var resolved: [Item] = []
        for id in ids {
            if let item = await resolveItem(id: id) { resolved.append(item) }
        }
        guard !resolved.isEmpty else { return }
        slideshowItems = resolved
        showingSlideshow = true
    }

    private var deleteDialogTitle: String {
        L10n.deleteSavedItemsTitle(pendingDelete.count)
    }

    private func deleteItems(_ ids: [String]) async {
        var failures = 0
        for id in ids {
            guard let item = await resolveItem(id: id) else { failures += 1; continue }
            do {
                try await viewModel.delete(item: item)
            } catch { failures += 1 }
        }
        let deleted = ids.count - failures
        pendingDelete = []
        exitSelection()
        // No notice on success. A partial failure is still reported,
        // like the Albums tab's errorMessage for the same case.
        if failures > 0 {
            viewModel.showToast(L10n.deletedCountPartial(deleted, failures), isError: true)
        }
    }

    // MARK: - Bulk actions

    private func shareSelection() async {
        let ids = Array(selection)
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
        for id in selection {
            guard let item = await resolveItem(id: id) else { continue }
            _ = await viewModel.toggleFavorite(item: item)
        }
    }

    private func presentAddToAlbum() async {
        var resolved: [Item] = []
        for id in selection {
            if let item = await resolveItem(id: id) { resolved.append(item) }
        }
        guard !resolved.isEmpty else {
            viewModel.showToast(L10n.loadItemsToAddFailed, isError: true)
            return
        }
        addToAlbumItems = resolved
        showingAddToAlbum = true
    }

    private func saveSelectionToPhotos() async {
        var saved = 0
        var failed = 0
        for id in selection {
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

    // MARK: - Single-item actions (context menu)

    private func saveToPhotos(_ id: String) async {
        guard let item = await resolveItem(id: id) else {
            viewModel.showToast("Không tải được mục này.", isError: true)
            return
        }
        await viewModel.saveToPhotosWithFeedback(item: item)
    }

    private func shareItem(_ id: String) async {
        guard let item = await resolveItem(id: id) else {
            viewModel.showToast(L10n.shareDownloadFailed, isError: true)
            return
        }
        do {
            shareFile = ShareFile(url: try await viewModel.shareFileURL(for: item))
        } catch {
            viewModel.showToast(L10n.shareDownloadFailed, isError: true)
        }
    }

    private func toggleFavorite(_ id: String) async {
        guard let item = await resolveItem(id: id) else { return }
        // No notice — the heart updates in place.
        _ = await viewModel.toggleFavorite(item: item)
    }

    private func openAddToAlbum(_ id: String) async {
        guard let item = await resolveItem(id: id) else { return }
        itemForAlbumPicker = item
    }

    // MARK: - Saving

    /// Saves a link right away, with no sheet in between. On success
    /// the Library refreshes and the new video is at the top of the
    /// grid; a duplicate shows a short notice instead of a second
    /// copy. When the link turns out to be a Collection, the notice
    /// reports how many videos were new (and how many were already
    /// saved); the videos are also grouped into a My collection
    /// named after the TikTok collection when it has a title. A
    /// failure surfaces through the view model's error alert.
    private func saveDirect(_ rawURL: String) async {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let result = await viewModel.save(url: trimmed) else { return }
        switch result {
        case .single(let single):
            if single.duplicate {
                viewModel.showToast("Link này đã lưu trước đó.")
            }
        case .collection(let coll):
            var notice = "Đã lưu \(coll.created) video mới"
            if coll.duplicates > 0 {
                notice += " (\(coll.duplicates) video đã có trước đó)"
            }
            if coll.capped {
                notice += " — chỉ lấy 100 video đầu"
            }
            if let title = coll.title, !title.isEmpty {
                notice = "Collection “\(title)”: " + notice
            }
            viewModel.showToast(notice + ".")
        }
    }

    /// Reads the first http(s) URL on the clipboard and saves it right
    /// away; warns when there is no link.
    private func saveDirectFromClipboard() async {
        if let notice = await viewModel.saveFromClipboard() {
            viewModel.showToast(notice)
        } else {
            viewModel.showToast(L10n.clipboardNoHttpLink, isError: true)
        }
    }
}

/// One cell in the square grids (Library All Photos / Days /
/// Months, and the album/collection detail grids): a SQUARE cell
/// (Photos style — no corner radius, 2pt gaps), the thumbnail
/// filling the square (centre-cropped, never letterboxed).
/// Badge bottom-right: the video duration ("0:25", Photos style),
/// or the view count when the duration is unknown. A spinner while
/// pending, a red dot when ingest failed, a white heart at the
/// bottom-left for a favorited item.
///
/// Tap is on this cell and the long-press menu is the native
/// `.contextMenu`, attached by the parent (no Button wrapper in the
/// parent): a Button around the cell swallowed the tap once a
/// long-press gesture was added inside it (v16 regression — cells
/// stopped opening the feed). With tap on the cell and the context
/// menu on the same view, SwiftUI resolves tap vs long-press
/// correctly.
struct PhotosGridCell: View {
    let item: Item
    /// Multi-select: when true the cell shows a selection circle
    /// (bottom-right, Photos) and a tap toggles selection (the
    /// parent's onTap decides). The long-press menu is the native
    /// `.contextMenu`, attached by the parent (LibraryView /
    /// PhotoCollectionScreen) — the cell itself has no long-press
    /// gesture. Unselected cells dim slightly in select mode; the
    /// duration badge and failed dot hide while selecting (the
    /// checkmark owns the bottom-right corner then).
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    /// Frame cache of the parent grid (a class, passed by reference):
    /// this cell writes its global frame straight into it — no
    /// PreferenceKey. Required (not defaulted): the synthesized
    /// memberwise init omits defaulted properties, so a defaulted
    /// cache could not be passed at the call site.
    let frameCache: CellFrameCache

    var body: some View {
        ZStack {
            AspectThumbnail(itemId: item.id)
                .opacity(isSelectionMode && !isSelected ? 0.7 : 1)
            // An uploading placeholder is not dimmed (the file
            // already exists on device) — it shows the progress
            // ring at the top-right instead. Other pending items
            // (server ingest) keep the dim + spinner.
            if item.status == .pending, item.uploadProgress == nil {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .tint(.white)
                }
            }
            if let progress = item.uploadProgress, progress < 1, !isSelectionMode {
                UploadProgressRing(progress: progress)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let badge = badgeText, item.status == .ready, !isSelectionMode {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if item.status == .failed, !isSelectionMode {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? .blue : .white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            }
        }
        .background(Color(.systemGray5))
        // Đợt 2 fix: bỏ viền xanh quanh cell khi select. Apple
        // Photos chỉ hiện checkmark, không thêm viền khung.
        // The tappable region is exactly this cell's square bounds.
        // Without an explicit content shape, the thumbnail's content
        // can shift hit-testing so a tap on the bottom edge lands on
        // the cell below. (The thumbnail itself stays square — the
        // ZStack + .aspectRatio in AspectThumbnail is untouched.)
        .contentShape(Rectangle())
        // Report this cell's global frame for the viewer's
        // shrink-to-thumbnail dismiss: written straight into the
        // `frameCache` (no PreferenceKey — preference propagation
        // on every scroll frame was a top drop-frame source). The
        // parent reads it from the cache at tap time.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { frameCache.set(item.id, geo.frame(in: .global)) }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        frameCache.set(item.id, newFrame)
                    }
            }
        )
        // One accessible element per cell (VoiceOver): the author /
        // title, video duration or photo, favorite state. Dynamic
        // Type scales the badge text automatically (caption2).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .onTapGesture {
            onTap?()
        }
    }

    /// VoiceOver description for the cell.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let author = item.authorUsername, !author.isEmpty {
            parts.append("@\(author)")
        } else if let author = item.author, !author.isEmpty {
            parts.append(author)
        }
        if let title = item.title, !title.isEmpty {
            parts.append(title)
        }
        if let duration = item.formattedDuration {
            parts.append("video, \(duration)")
        } else {
            parts.append("photo")
        }
        if item.isFavorite { parts.append("favorite") }
        if item.uploadProgress != nil { parts.append("uploading") }
        if item.status == .pending { parts.append("loading") }
        if item.status == .failed { parts.append("failed to save") }
        return parts.joined(separator: ", ")
    }

    /// Duration first (Photos style); view count when the duration
    /// is unknown (e.g. metadata that never came). Images show no
    /// badge at all — a still photo has no duration to display.
    private var badgeText: String? {
        guard item.contentType?.hasPrefix("image/") != true else { return nil }
        return item.formattedDuration ?? item.formattedViewCount
    }
}

extension PhotosGridCell: Equatable {
    /// Hot-path fix: when the parent's state changes, SwiftUI skips
    /// body evaluation for cells whose inputs did not change. `Item`
    /// is Equatable, so one `==` covers every item-derived field
    /// (status, favorite, badge, progress). The `onTap` closure is
    /// excluded (closures are not Equatable) and so is `frameCache`
    /// (same instance for the parent's lifetime).
    static func == (lhs: PhotosGridCell, rhs: PhotosGridCell) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.isSelected == rhs.isSelected
    }
}

/// Status badge: pending shows a spinner (ingest still running), ready is
/// green, failed is red with the ingest error visible in the detail view.
struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .pending {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(status.displayName)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }
}

/// Thumbnail loaded with an authenticated URLSession request.
/// AsyncImage cannot send an Authorization header, so it cannot load
/// GET /api/thumb/:id at all — this view exists because of that.
/// The image is kept in memory only; nothing is written to disk.
struct AuthenticatedThumbnail: View {
    let itemId: String
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var image: UIImage?

    init(item: Item) {
        self.itemId = item.id
    }

    init(itemId: String) {
        self.itemId = itemId
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: itemId) {
            guard image == nil, let api = viewModel.api else { return }
            image = await ThumbnailPipeline.shared.thumbnail(id: itemId, api: api)
        }
    }
}

/// A thumbnail forced to a fixed aspect ratio (square by default).
///
/// Why this exists: `.aspectRatio(1, .fit)` applied directly to an
/// `AuthenticatedThumbnail` (or to a `Group` wrapping one) does NOT
/// force the ratio once the image has loaded — the resizable `Image`
/// keeps its intrinsic 9:16 aspect and the cell renders tall
/// (v29 Albums screenshot: Recents stayed 9:16 while the Favorites
/// placeholder, a plain `Color`, did go square). A concrete `Color`
/// has no intrinsic aspect, so `.aspectRatio(.fit)` on it reliably
/// sizes the frame; the thumbnail then fills that frame via
/// `.overlay` (center-cropped by `.clipped()`), exactly like iOS
/// Photos' square thumbnails.
struct AspectThumbnail: View {
    let itemId: String
    var ratio: CGFloat = 1

    var body: some View {
        // Color.clear + .aspectRatio + .overlay is what forces the
        // square: a Color has no intrinsic aspect, so .aspectRatio
        // (.fit) reliably sizes the frame, and the thumbnail fills
        // it (scaledToFill, centre-cropped). A ZStack + .aspectRatio
        // does NOT force it — the resizable Image keeps its intrinsic
        // 9:16 aspect and the cell renders tall (v36 regression).
        // The tap offset the overlay pattern can cause is fixed by
        // the explicit .contentShape below: the hit area is exactly
        // this square's bounds, so a tap on the bottom edge lands on
        // this cell, not the one below it.
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                AuthenticatedThumbnail(itemId: itemId)
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

/// Identifiable wrapper so a downloaded file URL can drive a
/// `.sheet(item:)` — the iOS share sheet. Shared by the grid and the
/// player context menus.
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The iOS share sheet (UIActivityViewController) as a SwiftUI sheet.
/// Shared by the grid and the player context menus ("Share").
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Native iOS context menu for a grid thumbnail (long-press), in the
/// order the user asked for: Share, Save to Photos, Favorite, Add to
/// Album, Delete. This is the system menu — dark, large corner radius,
/// icons on the right of each row, Delete in red, smooth native
/// animation — and the pressed cell lifts as the menu's preview
/// (scale + shadow, like iOS Photos). The hold timing is iOS's native
/// long-press, not the old custom 0.25s.
///
/// Actions are closures so each grid (Library, a collection, My
/// collection, Search results) wires its own sheets/dialogs. The
/// menu is empty while multi-select is on (long-press is off there;
/// a tap toggles selection instead). `onRemoveFromCollection` is
/// only set by the My collection grid, where a video can leave the
/// collection without being deleted.
struct GridItemContextMenu: View {
    let item: Item
    let isSelecting: Bool
    let onSaveToPhotos: (Item) -> Void
    let onShare: (Item) -> Void
    let onToggleFavorite: (Item) -> Void
    let onAddToAlbum: (Item) -> Void
    let onDelete: (Item) -> Void
    var onRemoveFromCollection: ((Item) -> Void)? = nil

    var body: some View {
        Group {
            if !isSelecting {
                Button { onShare(item) } label: {
                    Label(L10n.share, systemImage: "square.and.arrow.up")
                }
                Button { onSaveToPhotos(item) } label: {
                    Label(L10n.saveToPhotos, systemImage: "arrow.down.to.line")
                }
                Button { onToggleFavorite(item) } label: {
                    Label(L10n.favorite, systemImage: item.isFavorite ? "heart.fill" : "heart")
                }
                Button { onAddToAlbum(item) } label: {
                    Label(L10n.addToAlbum, systemImage: "rectangle.stack.badge.plus")
                }
                if let onRemoveFromCollection {
                    Button { onRemoveFromCollection(item) } label: {
                        Label(L10n.removeFromAlbum, systemImage: "folder.badge.minus")
                    }
                }
                Button(role: .destructive) { onDelete(item) } label: {
                    Label(L10n.delete, systemImage: "trash")
                }
            }
        }
    }
}

/// Album picker shown after a Photos import: the user chooses which
/// album the just-uploaded items go into. Replaces the old
/// auto-"Imports" behavior (v50) — nothing is auto-added any more.
/// - Tap an album: the items go into it and the picker closes.
/// - "New Album" (the "+" button): name a new album, the items go
///   into it.
/// - "Edit": album rows show a red minus badge to delete an album
///   (same two choices as the Albums tab: Delete Album & Videos /
///   Delete Album Only).
/// - Cancel: the picker closes and the items stay in the Library,
///   in no album (they are still saved).
struct ImportAlbumPickerView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    /// Edit mode: red minus badges on album rows.
    @State private var isEditing = false
    /// "New Album" name alert (from the "+" button).
    @State private var showingNewAlbum = false
    @State private var newAlbumName = ""
    /// The album awaiting delete confirmation (nil = none).
    @State private var albumPendingDelete: MyCollection?
    @State private var showingDeleteConfirmation = false
    /// 2-column album grid (Photos See All style): 12pt gaps.
    private let pickerColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    /// "1 Photo" / "3 Photos" / "2 Videos" / "5 Items" for the items
    /// being added (Photos header style).
    private var addItemsLabel: String {
        let items = viewModel.importPickerItems
        let photos = items.filter { $0.contentType?.hasPrefix("image/") == true }.count
        let videos = items.count - photos
        if videos == 0 {
            return L10n.photoCount(items.count)
        } else if photos == 0 {
            return L10n.videoCount(items.count)
        } else {
            return L10n.itemsCount(items.count)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header: the items being added (Photos shows the
                    // first photo + "1 Photo"). While the upload is
                    // still running the picker shows progress instead.
                    if viewModel.isUploading {
                        Text(L10n.uploadingCount(viewModel.uploadDone, viewModel.uploadTotal))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let first = viewModel.importPickerItems.first {
                        HStack(spacing: 12) {
                            AspectThumbnail(itemId: first.id)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(addItemsLabel)
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                    }
                    // "New Album..." card (Photos): a gray placeholder
                    // with the Add-to-Album icon, same size as an
                    // album card, first in the grid.
                    LazyVGrid(columns: pickerColumns, spacing: 16) {
                        Button { showingNewAlbum = true } label: {
                            NewAlbumCardView()
                        }
                        .buttonStyle(.plain)
                    }
                    // "My Albums" section.
                    Text(L10n.myAlbums)
                        .font(.title2)
                        .bold()
                    if viewModel.myCollections.isEmpty {
                        Text(L10n.noAlbumsHint)
                            .foregroundStyle(.secondary)
                    }
                    // 2-column album grid with cover thumbnails,
                    // laid out like the Photos See All page (v57).
                    LazyVGrid(columns: pickerColumns, spacing: 16) {
                        ForEach(viewModel.myCollections) { collection in
                            // The minus badge is a SIBLING of the card
                            // button (not inside it): the card button
                            // is disabled in Edit mode, which would
                            // also disable a badge nested inside it.
                            ZStack(alignment: .topLeading) {
                                Button {
                                    Task { await viewModel.addImportItemsToAlbum(collection) }
                                } label: {
                                    PickerAlbumCardView(collection: collection)
                                }
                                .buttonStyle(.plain)
                                .disabled(isEditing)
                                // Red minus badge (Photos Edit mode).
                                if isEditing {
                                    Button {
                                        albumPendingDelete = collection
                                        showingDeleteConfirmation = true
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(.red)
                                            .background(Color.white, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: -8, y: -8)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(L10n.addToAlbum)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Photos puts Cancel at the top-right; Edit stays
                // at the top-left (the "+" is gone — the "New
                // Album..." card is the way to create an album).
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? L10n.done : L10n.edit) {
                        isEditing.toggle()
                    }
                    .fontWeight(isEditing ? .bold : .regular)
                    .foregroundStyle(.blue)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.cancel) {
                        viewModel.importPickerItems = []
                        viewModel.chosenImportAlbum = nil
                        viewModel.showingImportAlbumPicker = false
                    }
                    .foregroundStyle(.blue)
                }
            }
            .alert(L10n.newAlbum, isPresented: $showingNewAlbum) {
                TextField(L10n.title, text: $newAlbumName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.cancel, role: .cancel) { newAlbumName = "" }
                Button(L10n.save) {
                    let name = newAlbumName
                    newAlbumName = ""
                    Task { await viewModel.createImportAlbum(name: name) }
                }
                // (No .disabled here: the v57.2 .disabled lagged
                // behind typing in the alert, so the first tap on
                // Save did nothing. The Worker already rejects an
                // empty name with a clear error.)
            } message: {
                Text(L10n.newAlbumMessage)
            }
            .confirmationDialog(
                L10n.deleteAlbumTitle(albumPendingDelete?.name ?? ""),
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if let collection = albumPendingDelete {
                    Button(L10n.deleteAlbumAndVideos, role: .destructive) {
                        Task { await deleteAlbum(collection, deleteItems: true) }
                    }
                    Button(L10n.deleteAlbumOnly, role: .destructive) {
                        Task { await deleteAlbum(collection, deleteItems: false) }
                    }
                }
                Button(L10n.cancel, role: .cancel) { albumPendingDelete = nil }
            } message: {
                if let collection = albumPendingDelete {
                    Text(L10n.deleteAlbumMessage(collection.count))
                }
            }
        }
    }

    /// Delete an album from the picker's Edit mode. Refreshes the
    /// album list so the deleted album disappears at once.
    private func deleteAlbum(_ collection: MyCollection, deleteItems: Bool) async {
        do {
            try await viewModel.deleteMyCollection(id: collection.id, deleteItems: deleteItems)
        } catch {
            viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
