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
    /// The item the Photos detail viewer opens on (nil = closed).
    @State private var feedStartItem: Item?
    /// The global frame of the thumbnail the viewer opened from
    /// (nil = unknown): the viewer's dismiss drag shrinks the media
    /// onto it on release. Read from `cellFrameCache` at tap time.
    @State private var feedStartFrame: CGRect?
    /// Live cache of grid-cell global frames (see
    /// `CellFrameCache`): written by the cells' preference, read
    /// only when a cell is tapped.
    @State private var cellFrameCache = CellFrameCache()
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
    @State private var clipboardAlert = false
    /// One-line notice after an action (e.g. "already saved").
    @State private var saveNotice: String?

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
                        LazyVGrid(columns: allColumns, spacing: 2) {
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
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Haptics.select()
                            if allSelected {
                                selection.removeAll()
                            } else {
                                selection = Set(allIDs)
                            }
                        } label: {
                            Text(allSelected ? L10n.deselectAll : L10n.selectAll)
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
                        HStack(spacing: 16) {
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
                    saveNotice = added ? L10n.addedToCollection(name) : L10n.alreadyInCollection(name)
                },
                onCancel: { itemForAlbumPicker = nil }
            )
        }
        .sheet(isPresented: $showingAddToAlbum) {
            AddToAlbumSheet(
                ids: addToAlbumItems.map(\.id),
                onDone: { name, added in
                    saveNotice = L10n.addedCountToCollection(added, name)
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
        .alert("Kepto", isPresented: .constant(saveNotice != nil)) {
            Button("OK") { saveNotice = nil }
        } message: {
            Text(saveNotice ?? "")
        }
        .alert("Kepto", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Clipboard", isPresented: $clipboardAlert) {
            Button("OK") {}
        } message: {
            Text(L10n.clipboardNoHttpLink)
        }
        .onChange(of: zoom) { _, _ in
            Haptics.select()
            // Round-18: switching mode does NOT scroll — the grid
            // re-renders in the new zoom as before. Scroll-to-bottom
            // happens only on a re-tap of the active segment, via
            // ZoomSegmentBar's onRetap (scrollToBottomAnimated).
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

    private var dayColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: sizeClass == .regular ? 5 : 3)
    }

    private var allColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: sizeClass == .regular ? 8 : 4)
    }

    private var scroll: some View {
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
                    allPhotosGrid
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
            // the viewport. One anchor covers all four zooms: Years /
            // Months / Days / All Photos share this ScrollView.
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
            // The cells report their global frames (see `gridCell`):
            // keep them in the cache so a tap can hand the tapped cell's
            // frame to the viewer for its shrink-to-thumbnail dismiss.
            .onPreferenceChange(CellFramePreferenceKey.self) { frames in
                cellFrameCache.frames.merge(frames) { _, new in new }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: zoom)
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

    private var allPhotosGrid: some View {
        LazyVGrid(columns: allColumns, spacing: 2) {
            ForEach(windowedAllIDs, id: \.self) { id in
                gridCell(for: id)
            }
        }
    }

    /// The newest `visibleWindow` ids (the grid renders only these —
    /// see `visibleWindow`).
    private var windowedAllIDs: [String] {
        Array(allIDs.suffix(visibleWindow))
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
        // shrink-to-thumbnail dismiss (see `CellFramePreferenceKey`):
        // the frame is read from the cache at tap time, so the viewer
        // knows where its media must land on release.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: CellFramePreferenceKey.self, value: [id: geo.frame(in: .global)])
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
            if !selecting {
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
        let windowTop = max(allIDs.count - visibleWindow, 0)
        guard windowTop > 0, index <= windowTop + 10 else { return }
        guard let proxy = scrollProxy else { return }
        visibleWindow += 120
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    // MARK: - Scroll to bottom (Apple Photos order)

    /// The id to scroll to for "the bottom" (newest) in the current
    /// zoom: the last cell in All Photos / Days, the last card in
    /// Months / Years.
    private var scrollTargetID: String? {
        // Round-13: the target is the last of the WINDOWED list, so
        // the scrollTo lays out at most one window of cells — never
        // the whole library (the 46s freeze on open).
        switch zoom {
        case .all: windowedAllIDs.last
        case .days: windowedDays.last?.itemIDs.last
        case .months: months.last?.id
        case .years: years.last?.id
        }
    }

    /// Instant (no-animation) scroll to the bottom. The transaction
    /// disables animations outright — a plain scrollTo inside the
    /// zoom-animated ScrollView could otherwise visibly slide down.
    private func scrollToBottomInstant(_ proxy: ScrollViewProxy) {
        guard let id = scrollTargetID else { return }
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
        guard let proxy = scrollProxy, let id = scrollTargetID, !isAtBottom, feedStartItem == nil else { return }
        withAnimation(.easeOut(duration: 0.4)) { proxy.scrollTo(id, anchor: .bottom) }
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
    private func maybeInitialScroll(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll, !allIDs.isEmpty, feedStartItem == nil else { return }
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
    private func maybeScrollToNewItem(_ proxy: ScrollViewProxy, oldIDs: [String], newIDs: [String]) {
        guard (didInitialScroll || didFallbackScroll), feedStartItem == nil, !selecting else { return }
        guard zoom == .all || zoom == .days else { return }
        guard newIDs.count > oldIDs.count, let newLast = newIDs.last, newLast != oldIDs.last else { return }
        let isFreshImport = viewModel.justImportedIDs.contains(newLast)
        guard isAtBottom || isFreshImport else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(newLast, anchor: .bottom) }
        if isFreshImport { viewModel.clearJustImportedIDs() }
    }

    // MARK: - Multi-select

    private var allSelected: Bool {
        !allIDs.isEmpty && selection.count == allIDs.count
    }

    private var selectBar: some View {
        SelectBottomBar(
            enabled: !selection.isEmpty,
            onShare: { Task { await shareSelection() } },
            onFavorite: { Task { await favoriteSelection() } },
            onAdd: { Task { await presentAddToAlbum() } },
            onDelete: {
                pendingDelete = Array(selection)
                showDelete = true
            }
        ) {
            Menu {
                Button { Task { await saveSelectionToPhotos() } } label: {
                    Label(L10n.saveToPhotos, systemImage: "arrow.down.to.line")
                }
                Button { Task { await presentSlideshow() } } label: {
                    Label(L10n.slideshow, systemImage: "play.rectangle")
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                    Text(L10n.more)
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private func exitSelection() {
        selecting = false
        selection.removeAll()
    }

    private func handleTap(_ id: String) {
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
            saveNotice = L10n.deletedCountPartial(deleted, failures)
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
            saveNotice = L10n.shareDownloadFailed
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
            saveNotice = L10n.loadItemsToAddFailed
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
            saveNotice = "Đã lưu \(saved) vào Photos."
        } else {
            saveNotice = "Đã lưu \(saved) vào Photos, \(failed) lỗi."
        }
    }

    // MARK: - Single-item actions (context menu)

    private func saveToPhotos(_ id: String) async {
        guard let item = await resolveItem(id: id) else {
            saveNotice = "Không tải được mục này."
            return
        }
        do {
            try await viewModel.saveToPhotos(item: item)
            saveNotice = "Đã lưu vào Photos."
        } catch {
            saveNotice = "Không lưu được vào Photos."
        }
    }

    private func shareItem(_ id: String) async {
        guard let item = await resolveItem(id: id) else {
            saveNotice = L10n.shareDownloadFailed
            return
        }
        do {
            shareFile = ShareFile(url: try await viewModel.shareFileURL(for: item))
        } catch {
            saveNotice = L10n.shareDownloadFailed
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
                saveNotice = "Link này đã lưu trước đó."
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
            saveNotice = notice + "."
        }
    }

    /// Reads the first http(s) URL on the clipboard and saves it right
    /// away; warns when there is no link.
    private func saveDirectFromClipboard() async {
        if let notice = await viewModel.saveFromClipboard() {
            saveNotice = notice
        } else {
            clipboardAlert = true
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
    /// (top-left) and a tap toggles selection (the parent's onTap
    /// decides). The long-press menu is the native `.contextMenu`,
    /// attached by the parent (LibraryView / PhotoCollectionScreen) —
    /// the cell itself has no long-press gesture.
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack {
            AspectThumbnail(itemId: item.id)
            if item.status == .pending {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .tint(.white)
                }
            }
            if let badge = badgeText, item.status == .ready {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if item.status == .failed {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(.systemGray5))
        .overlay {
            if isSelected {
                Rectangle()
                    .stroke(.blue, lineWidth: 3)
            }
        }
        // The tappable region is exactly this cell's square bounds.
        // Without an explicit content shape, the thumbnail's content
        // can shift hit-testing so a tap on the bottom edge lands on
        // the cell below. (The thumbnail itself stays square — the
        // ZStack + .aspectRatio in AspectThumbnail is untouched.)
        .contentShape(Rectangle())
        // Report this cell's global frame for the viewer's
        // shrink-to-thumbnail dismiss (see `CellFramePreferenceKey`
        // in PhotoGridComponents): the parent reads it from its
        // `CellFrameCache` at tap time.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: CellFramePreferenceKey.self, value: [item.id: geo.frame(in: .global)])
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

/// Round-32 (grid P0): memoize the album cell. Without this, every
/// parent body evaluation (selection toggle, window growth, data
/// publish) rebuilt every visible cell's body, including its
/// AspectThumbnail subtree — the whole-grid re-render on scroll.
/// SwiftUI skips the body of an Equatable view when the new value
/// equals the old one, so `==` compares exactly the data this body
/// reads (id, status, favorite, author/title, duration/view count,
/// content type, selection state). `onTap` is deliberately NOT
/// compared: a fresh closure is created per render, and everything
/// it closes over is covered — `isSelecting` by isSelectionMode,
/// `item` by the fields above, and the frame cache is a class, so
/// the closure always reads live frames. Only used by
/// PhotoCollectionScreen (AlbumBrowser.swift).
extension PhotosGridCell: Equatable {
    static func == (lhs: PhotosGridCell, rhs: PhotosGridCell) -> Bool {
        lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.isSelected == rhs.isSelected
            && lhs.item.id == rhs.item.id
            && lhs.item.status == rhs.item.status
            && lhs.item.isFavorite == rhs.item.isFavorite
            && lhs.item.authorUsername == rhs.item.authorUsername
            && lhs.item.author == rhs.item.author
            && lhs.item.title == rhs.item.title
            && lhs.item.formattedDuration == rhs.item.formattedDuration
            && lhs.item.formattedViewCount == rhs.item.formattedViewCount
            && lhs.item.contentType == rhs.item.contentType
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
