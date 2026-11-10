import SwiftUI
import UIKit

/// Library view mode: the Photos-style Years / Months / Days /
/// All Photos switcher (a pill segmented control above the tab bar,
/// like Photos iOS 17.4). This is a presentation choice only — the
/// Library always loads the same flat list of all saved items.
enum LibraryViewMode: String, CaseIterable {
    case years, months, days, allPhotos

    var title: String {
        switch self {
        case .years: return "Years"
        case .months: return "Months"
        case .days: return "Days"
        case .allPhotos: return "All Photos"
        }
    }
}

/// Library: the Photos-style home tab. A flat grid of all saved
/// items (square thumbnails, 3 columns, 2pt gaps — like Photos'
/// All Photos), with a Years / Months / Days / All Photos switcher
/// and a "N Photos, M Videos" count in a pill above the tab bar.
/// The top-right has the Photos-style "Select" pill, a "+" save
/// menu, and a gear for Settings, floating over the grid.
/// Tapping a video opens it in the full-screen feed viewer; the
/// feed is only for watching, not the home itself.
/// Long-pressing a cell opens the native iOS context menu (Save to
/// Photos / Share / Favorite / Add to Album / Delete) — the cell
/// lifts as the menu's preview. In multi-select mode a tap toggles
/// the cell's selection instead, and the context menu is off.
/// Thumbnails are authenticated (AsyncImage cannot send the
/// Authorization header), so `AuthenticatedThumbnail` loads them
/// with URLSession and keeps them in memory only.
/// Dark mode is forced at the app root (KeptoTabView).
struct LibraryView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var showingSettings = false
    /// URL-input alert (shown by the "+" menu's "Lưu link mới").
    /// The Worker auto-detects a Collection link, so there is no
    /// separate "save collection" option any more.
    @State private var showingURLInput = false
    @State private var urlInput = ""
    @State private var clipboardAlert = false
    /// One-line notice after a direct save (e.g. "already saved").
    @State private var saveNotice: String?
    /// The video the full-screen feed viewer opens on (nil = closed).
    @State private var feedStartItem: Item?
    /// The video the context menu's "Add to Album" opened the picker
    /// for (nil = picker closed).
    @State private var itemForAlbumPicker: Item?
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// The video awaiting delete confirmation from the grid menu.
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false
    /// Multi-select mode for bulk delete: when true, tapping a cell
    /// toggles its selection instead of opening the feed, and a
    /// bottom bar offers Select All / Delete (N).
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showingBulkDeleteConfirmation = false
    /// The Photos-style view mode (Years / Months / Days / All Photos).
    @State private var viewMode: LibraryViewMode = .allPhotos

    /// 3-column square grid (Photos All Photos): 2pt gaps.
    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    /// 2-column grid for the Years view (one large tile per year).
    private let yearColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        // GeometryReader supplies the status-bar height
        // (`geometry.safeAreaInsets.top`): the top controls float
        // just below the status bar, over the first grid row. There
        // is no `@Environment(\.safeAreaInsets)` in SwiftUI — using
        // it fails the build ("generic parameter 'T' could not be
        // inferred", v29 log) — so the inset comes from here.
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                content
                if viewModel.isConfigured {
                    topControls(topInset: geometry.safeAreaInsets.top)
                }
            }
            .background(Color.black)
            .safeAreaInset(edge: .bottom) {
                if viewModel.isConfigured {
                    if isSelecting {
                        selectionBar
                    } else {
                        bottomBar
                    }
                }
            }
            .task {
                await viewModel.fetch()
                await viewModel.fetchStats()
            }
            .alert("Lưu link", isPresented: $showingURLInput) {
            TextField(
                "Dán link TikTok, Instagram…",
                text: $urlInput
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Lưu") {
                let url = urlInput
                urlInput = ""
                Task { await saveDirect(url) }
            }
            Button("Hủy", role: .cancel) { urlInput = "" }
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            viewModel.reloadConfig()
            Task { await viewModel.fetch() }
        }) {
            SettingsView()
        }
        .fullScreenCover(item: $feedStartItem) { startItem in
            FeedView(
                items: Binding(get: { viewModel.items }, set: { _ in }),
                startItemId: startItem.id,
                onNearEnd: { await viewModel.loadMore() },
                showCloseButton: true
            )
        }
        .sheet(item: $itemForAlbumPicker) { pickerItem in
            AddToCollectionPickerView(
                item: pickerItem,
                onAddedToCollection: { name, added in
                    saveNotice = added ? "Đã thêm vào \(name)." : "Đã có trong \(name)."
                },
                onCancel: { itemForAlbumPicker = nil }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.black)
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(activityItems: [file.url])
        }
        .confirmationDialog("Delete this saved item?",
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteGridMenuItem() }
            }
            Button("Cancel", role: .cancel) { itemPendingDelete = nil }
        } message: {
            Text(itemPendingDelete?.displayTitle ?? "")
        }
        .confirmationDialog("Delete \(selectedIDs.count) videos?",
                            isPresented: $showingBulkDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved copies from the cloud. This cannot be undone.")
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
            Text("Clipboard không có link http(s) nào.")
        }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.isConfigured {
            setupView
        } else {
            gridContent
        }
    }

    private var setupView: some View {
        ContentUnavailableView {
            Label("Set up Kepto", systemImage: "link.badge.plus")
        } description: {
            Text("Enter your Worker URL and API key in Settings to start saving.")
        } actions: {
            Button("Open Settings") { showingSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Top-right controls floating over the grid (Photos Library
    /// style): the "Select" pill, a "+" save menu, and a gear for
    /// Settings. They sit just below the status bar, over the first
    /// grid row — exactly where Photos puts Select / "…".
    private func topControls(topInset: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button(isSelecting ? "Cancel" : "Select") {
                toggleSelecting()
            }
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .buttonStyle(.plain)
            Menu {
                Button {
                    showingURLInput = true
                } label: {
                    Label("Lưu link mới", systemImage: "link.badge.plus")
                }
                Button {
                    Task { await saveDirectFromClipboard() }
                } label: {
                    Label("Lưu từ Clipboard", systemImage: "doc.on.clipboard")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
        }
        .padding(.top, topInset + 4)
        .padding(.trailing, 16)
    }

    /// Bottom bar above the tab bar (Photos Library style): the
    /// "N Photos, M Videos" count, then the Years / Months / Days /
    /// All Photos pill. Hidden while multi-select is on (the
    /// selection bar takes its place).
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let stats = viewModel.libraryStats {
                Text("\(stats.photos) Photos, \(stats.videos) Videos")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            viewModePicker
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    /// The view-mode pill: a dark capsule with the selected segment
    /// lighter, like Photos' Years / Months / Days / All Photos
    /// control at the bottom of the Library.
    private var viewModePicker: some View {
        HStack(spacing: 0) {
            ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                let selected = viewMode == mode
                Button {
                    viewMode = mode
                } label: {
                    Text(mode.title)
                        .font(.subheadline)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? .white : .white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selected ? Color.white.opacity(0.25) : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.12))
        .clipShape(Capsule())
    }

    /// The grid for the current view mode (loading / empty / grid).
    /// Tapping a video opens it in the full-screen feed viewer.
    @ViewBuilder
    private var gridContent: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView("Loading…")
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.items.isEmpty {
            ContentUnavailableView {
                Label("Nothing saved yet", systemImage: "tray")
            } description: {
                Text("Tap + and paste a link from TikTok, Instagram, Threads, X, Facebook, Douyin, or YouTube.")
            } actions: {
                Button("Save a link") { showingURLInput = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch viewMode {
            case .allPhotos: allPhotosGrid
            case .days: daysGrid
            case .months: monthsGrid
            case .years: yearsGrid
            }
        }
    }

    /// All Photos: the flat 3-column square grid (Photos style).
    /// The last cell loads the next page when it appears
    /// (waterfall); pull-to-refresh reloads.
    private var allPhotosGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 2) {
                ForEach(viewModel.items) { item in
                    gridCell(for: item)
                }
            }
        }
        .refreshable {
            await viewModel.fetch()
        }
    }

    /// Days: one section per day (newest first), each with a date
    /// header and a 3-column square grid.
    private var daysGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(itemsByDay, id: \.key) { group in
                    Text(Self.dayFormatter.string(from: group.key))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(group.items) { item in
                            gridCell(for: item)
                        }
                    }
                }
            }
        }
        .refreshable {
            await viewModel.fetch()
        }
    }

    /// Months: one section per month (newest first), each with a
    /// month header and a 3-column square grid.
    private var monthsGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(itemsByMonth, id: \.key) { group in
                    Text(Self.monthFormatter.string(from: group.key))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(group.items) { item in
                            gridCell(for: item)
                        }
                    }
                }
            }
        }
        .refreshable {
            await viewModel.fetch()
        }
    }

    /// Years: one large tile per year (2 columns) — the year's
    /// newest item as the cover, the year, and the item count.
    /// Tapping a tile opens the feed at that year's newest video.
    private var yearsGrid: some View {
        ScrollView {
            LazyVGrid(columns: yearColumns, spacing: 12) {
                ForEach(itemsByYear, id: \.key) { group in
                    if let first = group.items.first {
                        Button {
                            feedStartItem = first
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AuthenticatedThumbnail(item: first)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipped()
                                Text(Self.yearFormatter.string(from: group.key))
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("\(group.items.count) items")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if viewModel.hasMore {
                Button("Load more") {
                    Task { await viewModel.loadMore() }
                }
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .refreshable {
            await viewModel.fetch()
        }
    }

    /// One grid cell with the native iOS context menu (Save to
    /// Photos / Share / Favorite / Add to Album / Delete) and the
    /// waterfall load-more on the last item. Shared by the All
    /// Photos, Days, and Months grids.
    private func gridCell(for item: Item) -> some View {
        PhotosGridCell(
            item: item,
            isSelectionMode: isSelecting,
            isSelected: selectedIDs.contains(item.id),
            onTap: {
                if isSelecting {
                    toggleSelection(item)
                } else {
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
                onDelete: { requestGridDelete($0) }
            )
        }
        .onAppear {
            if item.id == viewModel.items.last?.id {
                Task { await viewModel.loadMore() }
            }
        }
    }

    // MARK: - View-mode grouping

    /// Loaded items grouped by day (newest day first).
    private var itemsByDay: [(key: Date, items: [Item])] {
        groupItems(by: [.year, .month, .day])
    }

    /// Loaded items grouped by month (newest month first).
    private var itemsByMonth: [(key: Date, items: [Item])] {
        groupItems(by: [.year, .month])
    }

    /// Loaded items grouped by year (newest year first).
    private var itemsByYear: [(key: Date, items: [Item])] {
        groupItems(by: [.year])
    }

    /// Groups the loaded items by the given calendar components
    /// (from each item's saved date), newest group first. Items
    /// whose saved date does not parse are skipped.
    private func groupItems(by components: Set<Calendar.Component>) -> [(key: Date, items: [Item])] {
        let calendar = Calendar.current
        var groups: [Date: [Item]] = [:]
        for item in viewModel.items {
            guard let date = item.savedDate else { continue }
            let comps = calendar.dateComponents(components, from: date)
            guard let key = calendar.date(from: comps) else { continue }
            groups[key, default: []].append(item)
        }
        return groups.map { (key: $0.key, items: $0.value) }.sorted { $0.key > $1.key }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()

    // MARK: - Multi-select

    /// Bottom bar in multi-select mode: Select All / Deselect All
    /// and Delete (N). (A separate property so `body` stays small
    /// enough for the compiler — see FeedView's type-check lesson.)
    private var selectionBar: some View {
        SelectionActionBar(
            selectedCount: selectedIDs.count,
            totalCount: viewModel.items.count,
            onSelectAll: { selectAll() },
            onDelete: { showingBulkDeleteConfirmation = true }
        )
    }

    /// Enter/exit multi-select mode. Exiting clears the selection.
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
    }

    /// Toggle one video's selection.
    private func toggleSelection(_ item: Item) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// Select all videos currently loaded in this grid (the grid
    /// pages, so this is the loaded set, not the whole library).
    private func selectAll() {
        if selectedIDs.count == viewModel.items.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(viewModel.items.map(\.id))
        }
    }

    /// Delete every selected video (sequential, reusing the single
    /// delete), then exit multi-select mode. Failures are counted
    /// and reported; the rest still delete.
    private func deleteSelected() async {
        let targets = viewModel.items.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        var failures = 0
        for item in targets {
            do {
                try await viewModel.delete(item: item)
            } catch {
                failures += 1
            }
        }
        let deleted = targets.count - failures
        selectedIDs.removeAll()
        isSelecting = false
        if failures == 0 {
            saveNotice = "Đã xóa \(deleted) video."
        } else {
            saveNotice = "Đã xóa \(deleted) video, \(failures) video lỗi."
        }
    }

    // MARK: - Context menu actions

    /// Context menu "Save to Photos": download the item and save it
    /// to the Photos library. The notice reuses the save-notice line.
    private func saveToPhotos(_ item: Item) {
        Task {
            do {
                try await viewModel.saveToPhotos(item: item)
                saveNotice = "Đã lưu vào Photos."
            } catch {
                saveNotice = "Không lưu được vào Photos."
            }
        }
    }

    /// Context menu "Share": download the item's file, then open the
    /// iOS share sheet with it.
    private func shareItem(_ item: Item) {
        Task {
            do {
                shareFile = ShareFile(url: try await viewModel.shareFileURL(for: item))
            } catch {
                saveNotice = "Không tải được file để chia sẻ."
            }
        }
    }

    /// Context menu "Favorite": toggle the heart, with a notice.
    private func toggleGridFavorite(_ item: Item) {
        Task {
            if let updated = await viewModel.toggleFavorite(item: item) {
                saveNotice = updated.isFavorite ? "Đã thêm vào Favorite." : "Đã bỏ Favorite."
            }
        }
    }

    /// Context menu "Delete": show the delete confirmation for this
    /// video. (No sheet to dismiss first, unlike the old bottom-sheet
    /// menu — the confirmation can appear immediately.)
    private func requestGridDelete(_ item: Item) {
        itemPendingDelete = item
        showingDeleteConfirmation = true
    }

    /// Delete the video pending confirmation from the grid menu.
    private func deleteGridMenuItem() async {
        guard let target = itemPendingDelete else { return }
        itemPendingDelete = nil
        do {
            try await viewModel.delete(item: target)
        } catch {
            viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
        guard let text = UIPasteboard.general.string,
              let url = Self.firstURL(in: text) else {
            clipboardAlert = true
            return
        }
        await saveDirect(url.absoluteString)
    }

    private static func firstURL(in text: String) -> URL? {
        let pattern = "https?://[^\\s\"'<>]+"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
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
    /// attached by the parent (LibraryView / CollectionDetailView) —
    /// the cell itself has no long-press gesture.
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack {
            AuthenticatedThumbnail(item: item)
                // NOTE: `.fit`, NOT `.fill`. With `.fill` the cell
                // falls back to the video's intrinsic 9:16 aspect
                // when the grid proposes a flexible height, so the
                // grid rendered tall portrait cells instead of
                // squares (v29 screenshots). `.fit` forces 1:1.
                .aspectRatio(1, contentMode: .fit)
                .clipped()
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
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(.systemGray5))
        .overlay {
            if isSelected {
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .onTapGesture {
            onTap?()
        }
    }

    /// Duration first (Photos style); view count when the duration
    /// is unknown (e.g. an image post, or metadata that never came).
    private var badgeText: String? {
        item.formattedDuration ?? item.formattedViewCount
    }
}

/// Bottom bar shown in multi-select mode: Select All / Deselect All
/// and Delete (N). Shared by the Library grid and the collection
/// grids. `totalCount` is the number of videos currently loaded in
/// the grid (the grid pages, so Select All covers the loaded set).
struct SelectionActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onSelectAll: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(allSelected ? "Deselect All" : "Select All", action: onSelectAll)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Spacer()
            Text("\(selectedCount) selected")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button(action: onDelete) {
                Text("Delete (\(selectedCount))")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(selectedCount > 0 ? Color.red : Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var allSelected: Bool {
        selectedCount > 0 && selectedCount == totalCount
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
/// order the user asked for: Save to Photos, Share, Favorite, Add to
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
                Button { onSaveToPhotos(item) } label: {
                    Label("Save to Photos", systemImage: "arrow.down.to.line")
                }
                Button { onShare(item) } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button { onToggleFavorite(item) } label: {
                    Label("Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart")
                }
                Button { onAddToAlbum(item) } label: {
                    Label("Add to Album", systemImage: "folder.badge.plus")
                }
                if let onRemoveFromCollection {
                    Button { onRemoveFromCollection(item) } label: {
                        Label("Remove from Album", systemImage: "folder.badge.minus")
                    }
                }
                Button(role: .destructive) { onDelete(item) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

/// For You: Photos-style suggestions. "Memories" groups the saved
/// items by month (one large card per month — the month's newest
/// item as a 16:9 cover, the month, and the item count), and
/// "Featured Photos" is a horizontal strip of recent items.
/// Tapping a memory or a featured photo opens the feed at that
/// video (paging through the whole library). No fake content —
/// everything here is built from the user's real saved items.
struct ForYouView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var feedStartItem: Item?

    var body: some View {
        NavigationStack {
            ScrollView {
                if viewModel.items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing saved yet", systemImage: "heart.text.square")
                    } description: {
                        Text("Save some videos and photos — memories and featured picks will show up here.")
                    }
                    .padding(.top, 40)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        memoriesSection
                        featuredSection
                    }
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("For You")
            .refreshable {
                await viewModel.fetch()
            }
            .task {
                if viewModel.items.isEmpty {
                    await viewModel.fetch()
                }
            }
            .fullScreenCover(item: $feedStartItem) { startItem in
                FeedView(
                    items: Binding(get: { viewModel.items }, set: { _ in }),
                    startItemId: startItem.id,
                    onNearEnd: { await viewModel.loadMore() },
                    showCloseButton: true
                )
            }
        }
    }

    /// One large card per saved month (newest first).
    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memories")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            ForEach(memories, id: \.key) { memory in
                if let first = memory.items.first {
                    Button {
                        feedStartItem = first
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            AuthenticatedThumbnail(item: first)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(Self.monthFormatter.string(from: memory.key))
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("\(memory.items.count) items")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A horizontal strip of recent items.
    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Featured Photos")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(featuredItems) { item in
                        Button {
                            feedStartItem = item
                        } label: {
                            AuthenticatedThumbnail(item: item)
                                .frame(width: 140, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// The 10 most recent items.
    private var featuredItems: [Item] {
        Array(viewModel.items.prefix(10))
    }

    /// Loaded items grouped by saved month (newest month first).
    private var memories: [(key: Date, items: [Item])] {
        let calendar = Calendar.current
        var groups: [Date: [Item]] = [:]
        for item in viewModel.items {
            guard let date = item.savedDate else { continue }
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let key = calendar.date(from: comps) else { continue }
            groups[key, default: []].append(item)
        }
        return groups.map { (key: $0.key, items: $0.value) }.sorted { $0.key > $1.key }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}

/// Search: a Photos-style search tab. A search bar at the top
/// (placeholder "Photos, People, Places…", mic icon on the right
/// like Photos), a Categories section below (platforms, then top
/// creators — each a square cover + label), and search results as
/// a square 3-column grid. Tapping a category runs that search;
/// typing searches by title / caption / author (debounced).
/// Long-pressing a result opens the same native context menu as
/// the Library grid; tapping one opens the feed.
struct SearchView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var query = ""
    @State private var selectedPlatform: Platform?
    @State private var searchTask: Task<Void, Never>?
    @State private var feedStartItem: Item?
    @State private var itemForAlbumPicker: Item?
    @State private var shareFile: ShareFile?
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false
    @State private var saveNotice: String?

    /// 3-column square grid (Photos style): 2pt gaps.
    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    /// True when a text query or a platform category is active.
    private var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPlatform != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if isSearchActive {
                    searchResultsContent
                } else {
                    categoriesContent
                }
            }
            .navigationTitle("Search")
            .onChange(of: query) { _, _ in
                scheduleSearch()
            }
            .onChange(of: selectedPlatform) { _, _ in
                Task { await performSearch() }
            }
            .fullScreenCover(item: $feedStartItem) { startItem in
                FeedView(
                    items: Binding(get: { viewModel.searchResults }, set: { _ in }),
                    startItemId: startItem.id,
                    onNearEnd: { await viewModel.searchMore() },
                    showCloseButton: true
                )
            }
            .sheet(item: $itemForAlbumPicker) { pickerItem in
                AddToCollectionPickerView(
                    item: pickerItem,
                    onAddedToCollection: { name, added in
                        saveNotice = added ? "Đã thêm vào \(name)." : "Đã có trong \(name)."
                    },
                    onCancel: { itemForAlbumPicker = nil }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
            }
            .sheet(item: $shareFile) { file in
                ShareSheet(activityItems: [file.url])
            }
            .confirmationDialog("Delete this saved item?",
                                isPresented: $showingDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await deleteGridMenuItem() }
                }
                Button("Cancel", role: .cancel) { itemPendingDelete = nil }
            } message: {
                Text(itemPendingDelete?.displayTitle ?? "")
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
        }
    }

    /// The search bar (Photos style): a rounded dark field with a
    /// magnifier, the "Photos, People, Places…" placeholder, a clear
    /// button while typing, and a mic icon on the right (decorative —
    /// voice search is not implemented).
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("Photos, People, Places…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Image(systemName: "mic.fill")
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Categories (shown when no search is active): platforms, then
    /// the most-saved creators. Each is a square cover + label;
    /// tapping one runs that search.
    private var categoriesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !platformCategories.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Categories")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(platformCategories, id: \.platform) { category in
                                    SearchCategoryCard(
                                        title: category.platform.displayName,
                                        coverItem: category.cover
                                    ) {
                                        selectedPlatform = selectedPlatform == category.platform ? nil : category.platform
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                if !authorCategories.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("People")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(authorCategories, id: \.name) { category in
                                    SearchCategoryCard(title: category.name, coverItem: category.cover) {
                                        query = category.name
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                if platformCategories.isEmpty && authorCategories.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing saved yet", systemImage: "magnifyingglass")
                    } description: {
                        Text("Save some links and categories will show up here.")
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
    }

    /// Search results as a square 3-column grid (Photos style).
    private var searchResultsContent: some View {
        Group {
            if viewModel.searchResults.isEmpty {
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing saved matches this search yet.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(viewModel.searchResults) { item in
                            searchCell(for: item)
                        }
                    }
                }
            }
        }
    }

    /// One result cell with the native context menu and the
    /// waterfall load-more on the last result.
    private func searchCell(for item: Item) -> some View {
        PhotosGridCell(
            item: item,
            onTap: { feedStartItem = item }
        )
        .contextMenu {
            GridItemContextMenu(
                item: item,
                isSelecting: false,
                onSaveToPhotos: { saveToPhotos($0) },
                onShare: { shareItem($0) },
                onToggleFavorite: { toggleGridFavorite($0) },
                onAddToAlbum: { itemForAlbumPicker = $0 },
                onDelete: { requestGridDelete($0) }
            )
        }
        .onAppear {
            if item.id == viewModel.searchResults.last?.id {
                Task { await viewModel.searchMore() }
            }
        }
    }

    // MARK: - Categories

    /// One category per platform that has saved items (cover = the
    /// platform's newest saved item).
    private var platformCategories: [(platform: Platform, cover: Item)] {
        var result: [(Platform, Item)] = []
        for platform in Platform.allCases {
            if let first = viewModel.items.first(where: { $0.platform == platform }) {
                result.append((platform, first))
            }
        }
        return result
    }

    /// The most-saved creators (up to 8), cover = the creator's
    /// newest saved item.
    private var authorCategories: [(name: String, cover: Item)] {
        var counts: [String: (count: Int, first: Item)] = [:]
        for item in viewModel.items {
            let name = item.collectionName
            if var entry = counts[name] {
                entry.count += 1
                counts[name] = entry
            } else {
                counts[name] = (count: 1, first: item)
            }
        }
        return counts
            .map { (name: $0.key, count: $0.value.count, cover: $0.value.first) }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { (name: $0.name, cover: $0.cover) }
    }

    // MARK: - Search

    /// Debounce: wait for the user to stop typing before hitting
    /// the server with a new query.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    /// Runs the current search (text query and/or platform). With
    /// no query and no platform, clears the results instead.
    private func performSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty && selectedPlatform == nil {
            viewModel.clearSearch()
            return
        }
        await viewModel.search(query: q.isEmpty ? nil : q, platform: selectedPlatform)
    }

    // MARK: - Context menu actions

    private func saveToPhotos(_ item: Item) {
        Task {
            do {
                try await viewModel.saveToPhotos(item: item)
                saveNotice = "Đã lưu vào Photos."
            } catch {
                saveNotice = "Không lưu được vào Photos."
            }
        }
    }

    private func shareItem(_ item: Item) {
        Task {
            do {
                shareFile = ShareFile(url: try await viewModel.shareFileURL(for: item))
            } catch {
                saveNotice = "Không tải được file để chia sẻ."
            }
        }
    }

    private func toggleGridFavorite(_ item: Item) {
        Task {
            if let updated = await viewModel.toggleFavorite(item: item) {
                saveNotice = updated.isFavorite ? "Đã thêm vào Favorite." : "Đã bỏ Favorite."
            }
        }
    }

    private func requestGridDelete(_ item: Item) {
        itemPendingDelete = item
        showingDeleteConfirmation = true
    }

    private func deleteGridMenuItem() async {
        guard let target = itemPendingDelete else { return }
        itemPendingDelete = nil
        do {
            try await viewModel.delete(item: target)
        } catch {
            viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// One search category card (Photos Search style): a square cover
/// with the category name below it.
private struct SearchCategoryCard: View {
    let title: String
    let coverItem: Item?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let coverItem {
                        AuthenticatedThumbnail(item: coverItem)
                    } else {
                        ZStack {
                            Color(.systemGray5)
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
