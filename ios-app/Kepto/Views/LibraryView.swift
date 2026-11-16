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
/// Kepto features kept: the "…" menu (Import from Photos, Paste
/// Clipboard, Settings), the Save-a-link alert, the setup view
/// when unconfigured, and the feed viewer for now (step 7 replaces
/// it with Photos' detail viewer). No `PhotoLibraryService`, no
/// `PHAsset` anywhere in this file.
struct LibraryView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var zoom: LibraryZoom = .days
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

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.isConfigured {
                    setupView
                } else if viewModel.isLoading && viewModel.items.isEmpty && viewModel.allMetadata.isEmpty {
                    LoadingLibraryView()
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
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.cancel) { exitSelection() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(allSelected ? L10n.deselectAll : L10n.selectAll) {
                            Haptics.select()
                            if allSelected {
                                selection.removeAll()
                            } else {
                                selection = Set(allIDs)
                            }
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            Button(L10n.select) {
                                Haptics.tap()
                                selecting = true
                            }
                            .disabled(allIDs.isEmpty)
                            Menu {
                                Button { viewModel.showingPhotoPicker = true } label: {
                                    Label(L10n.importFromPhotos, systemImage: "photo.on.rectangle")
                                }
                                Button { Task { await saveDirectFromClipboard() } } label: {
                                    Label(L10n.pasteClipboard, systemImage: "doc.on.clipboard")
                                }
                                Button { showingSettings = true } label: {
                                    Label(L10n.settings, systemImage: "gearshape")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 20))
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
                    ZoomSegmentBar(zoom: $zoom)
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
            // Inside the NavigationStack (not on the outer view): a
            // navigationDestination attached outside the stack never
            // presents — that was why tapping a cell did not open the
            // Player.
            .navigationDestination(item: $feedStartItem) { startItem in
                PhotoDetailView(
                    items: Binding(get: { viewModel.items }, set: { _ in }),
                    startItemId: startItem.id,
                    onNearEnd: { await viewModel.loadMore() },
                    title: L10n.library,
                    sourceFrame: feedStartFrame
                )
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
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.black)
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
        // Bottom margin so the last row scrolls clear of the
        // floating Years/Months/Days/All Photos pill.
        .contentMargins(.bottom, 64, for: .scrollContent)
        .background(Color(uiColor: .systemBackground))
        .simultaneousGesture(pinch)
        // The cells report their global frames (see `gridCell`):
        // keep them in the cache so a tap can hand the tapped cell's
        // frame to the viewer for its shrink-to-thumbnail dismiss.
        .onPreferenceChange(CellFramePreferenceKey.self) { frames in
            cellFrameCache.frames.merge(frames) { _, new in new }
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
                AssetThumbnail(source: source, cornerRadius: 12)
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
            ForEach(days) { day in
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
            ForEach(allIDs, id: \.self) { id in
                gridCell(for: id)
            }
        }
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
        .onAppear { maybeLoadMore(before: id) }
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

    /// All ids in the Library, newest first. The full metadata cache
    /// when it is loaded; the loaded pages while listAll is still
    /// pending or failed (so the Library never goes blank when the
    /// metadata fetch has not finished yet).
    private var allIDs: [String] {
        viewModel.allMetadataLoaded ? viewModel.allMetadata.map(\.id) : viewModel.items.map(\.id)
    }

    /// The thumbnail source for one id: light metadata first, the
    /// loaded full `Item` as fallback (while the metadata cache is
    /// still loading).
    private func source(for id: String) -> (any GridItemSource)? {
        if let meta = metadataById[id] { return meta }
        return viewModel.items.first { $0.id == id }
    }

    private var metadataById: [String: ItemMetadata] {
        Dictionary(viewModel.allMetadata.map { ($0.id, $0) }) { _, last in last }
    }

    /// Grouped ids for one zoom level: the full-metadata groupings
    /// when loaded, else the loaded pages grouped the same way (the
    /// old `groupItems` logic — sections stay correct, just partial
    /// until listAll lands).
    private func groupedIDs(by components: Set<Calendar.Component>) -> [(key: Date, ids: [String])] {
        if viewModel.allMetadataLoaded {
            return viewModel.groupedMetadata(by: components).map { (key: $0.key, ids: $0.items.map(\.id)) }
        }
        let calendar = Calendar.current
        var groups: [Date: [String]] = [:]
        for item in viewModel.items {
            guard let date = item.savedDate else { continue }
            let comps = calendar.dateComponents(components, from: date)
            guard let key = calendar.date(from: comps) else { continue }
            groups[key, default: []].append(item.id)
        }
        return groups.map { (key: $0.key, ids: $0.value) }.sorted { $0.key > $1.key }
    }

    private var days: [DaySection] {
        groupedIDs(by: [.year, .month, .day]).map { group in
            DaySection(id: Self.dayIDFormatter.string(from: group.key), date: group.key, title: DateLabels.dayTitle(for: group.key), subtitle: nil, itemIDs: group.ids)
        }
    }

    private var months: [MonthSection] {
        groupedIDs(by: [.year, .month]).map { group in
            MonthSection(id: Self.monthIDFormatter.string(from: group.key), date: group.key, title: DateLabels.monthTitle(for: group.key), itemIDs: group.ids, coverID: group.ids.first)
        }
    }

    private var years: [YearSection] {
        groupedIDs(by: [.year]).map { group in
            let year = Calendar.current.component(.year, from: group.key)
            return YearSection(year: year, title: String(year), itemIDs: group.ids, coverIDs: Array(group.ids.prefix(4)))
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
    /// page by page. When a cell appears near the end of the loaded
    /// range, load the next page in the background.
    private func maybeLoadMore(before id: String) {
        guard viewModel.hasMore, !viewModel.items.isEmpty else { return }
        guard let index = allIDs.firstIndex(of: id), index >= viewModel.items.count - 10 else { return }
        Task { await viewModel.loadMore() }
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
        if failures == 0 {
            saveNotice = L10n.deletedCount(deleted)
        } else {
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
        if let updated = await viewModel.toggleFavorite(item: item) {
            saveNotice = updated.isFavorite ? "Đã thêm vào Favorite." : "Đã bỏ Favorite."
        }
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
/// pending, a red dot when ingest failed, a red heart at the
/// top-right for a favorited video.
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
                    .foregroundStyle(.red)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
            image = try? await api.fetchThumbnail(id: itemId)
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
/// The "New Album..." card at the top of the Add to Album sheet
/// (Photos): a gray placeholder with the stacked-photos icon and
/// the "New Album..." label below, same size as an album card.
/// Tapping it opens the New Album name alert.
private struct NewAlbumCardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.systemGray5)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(L10n.newAlbum + "...")
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// One album card in the import picker: cover thumbnail + name +
/// count, laid out like the Photos See All grid (square cover,
/// name + count underneath, regular weight — not bold).
private struct PickerAlbumCardView: View {
    let collection: MyCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let coverItemId = collection.coverItemId {
                    AspectThumbnail(itemId: coverItemId)
                } else {
                    Color(.systemGray5)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(collection.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(collection.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // The tappable region is exactly this card's bounds: a tap
        // on the bottom edge must pick this album, not the one
        // below it.
        .contentShape(Rectangle())
    }
}

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
                    // with the stacked-photos icon, same size as an
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
