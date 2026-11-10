import SwiftUI
import UIKit

/// Library: the app's home screen. The home shows saved videos as a
/// 3-column grid (TikTok profile style) — Tất cả (all) / Reels
/// (videos) / Bài viết (images) / Collections. Tapping a video opens
/// it in the full-screen feed viewer (swipe up/down for the next
/// video); the feed is only for watching, not the home itself.
/// The search field and the section menu stay on screen for every
/// section (including Collections) — they are shared chrome, not
/// part of the video grid, so switching sections never loses the menu.
/// Collections show the user's own collections ("My collections",
/// with a New card) on top and the per-creator collections below;
/// tapping a collection opens its videos in a grid, and tapping one
/// there opens the feed viewer too.
/// Searching filters the grid. Thumbnails are authenticated
/// (AsyncImage cannot send the Authorization header), so
/// `AuthenticatedThumbnail` loads them with URLSession (see
/// `KeptoAPI.fetchThumbnail`) and keeps them in memory only.
struct LibraryView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var showingSettings = false
    @State private var searchTask: Task<Void, Never>?
    @State private var clipboardAlert = false
    /// URL-input alert (shown by the "+" menu's "Lưu link mới").
    /// The Worker auto-detects a Collection link, so there is no
    /// separate "save collection" option any more.
    @State private var showingURLInput = false
    @State private var urlInput = ""
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
    /// "New collection" name alert (from the Collections section).
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    /// The collection whose detail page is open (nil = closed).
    /// Navigation is a Button + navigationDestination, NOT an inline
    /// NavigationLink in the LazyVGrid: inline links in a lazy grid
    /// are flaky on iOS 17 (some cards simply never navigate).
    @State private var selectedCollection: CollectionInfo?
    @State private var selectedMyCollection: MyCollection?

    private let collectionColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    /// 3-column video grid (TikTok profile style): 9:16 cells, 2pt
    /// gaps, slightly rounded corners.
    private let videoColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                if viewModel.isConfigured && !isSelecting {
                    addButton
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    selectionBar
                }
            }
            .navigationTitle("Kepto")
            .navigationDestination(item: $selectedCollection) { collection in
                CollectionDetailView(collection: collection)
            }
            .navigationDestination(item: $selectedMyCollection) { collection in
                MyCollectionDetailView(collection: collection)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isConfigured && showsVideoGrid {
                        Button(isSelecting ? "Cancel" : "Select") {
                            toggleSelecting()
                        }
                    }
                }
            }
            .onChange(of: viewModel.searchText) { _, _ in
                // Debounce: wait for the user to stop typing before
                // hitting the server with a new `q` query.
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await viewModel.fetch()
                }
            }
            .onChange(of: viewModel.selectedSection) { _, _ in
                // Leaving the video grid (e.g. to Collections) ends
                // multi-select: the selection belongs to that grid.
                exitSelectionMode()
            }
            .task {
                await viewModel.selectSection(viewModel.selectedSection)
            }
            .onChange(of: viewModel.pendingShareURL) { _, newValue in
                // A link handed over by the Share Extension: save it
                // directly (no sheet) and clear the handoff.
                if let newValue {
                    viewModel.pendingShareURL = nil
                    Task { await saveDirect(newValue) }
                }
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
            .alert("New collection", isPresented: $showingNewCollection) {
                TextField("Tên collection", text: $newCollectionName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Tạo") {
                    let name = newCollectionName
                    newCollectionName = ""
                    Task {
                        if let created = await viewModel.createMyCollection(name: name) {
                            saveNotice = "Đã tạo collection \"\(created.name)\"."
                        }
                    }
                }
                Button("Hủy", role: .cancel) { newCollectionName = "" }
            }
            .alert("Kepto", isPresented: .constant(saveNotice != nil)) {
                Button("OK") { saveNotice = nil }
            } message: {
                Text(saveNotice ?? "")
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                viewModel.reloadConfig()
                Task { await viewModel.selectSection(viewModel.selectedSection) }
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

    /// Floating "+" button (bottom-right): opens a menu to save a new
    /// link, or save the link currently on the clipboard. Choosing
    /// either starts the save right away — no further sheet or menu.
    /// (No Photo Library entry: Kepto saves by link, it has no
    /// local-file upload.)
    private var addButton: some View {
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
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    /// Saves a link right away, with no sheet in between. On success
    /// the home switches to Tất cả and the new video is at the top of
    /// the grid; a duplicate shows a short notice instead of a second
    /// copy. When the link turns out to be a Collection, the notice
    /// reports how many videos were new (and how many were already
    /// saved); the videos are also grouped into a My collection
    /// named after the TikTok collection when it has a title. A
    /// failure surfaces through the view model's error alert.
    private func saveDirect(_ rawURL: String) async {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let result = await viewModel.save(url: trimmed) else { return }
        await viewModel.selectSection(.all)
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

    @ViewBuilder
    private var content: some View {
        if !viewModel.isConfigured {
            setupView
        } else {
            // The search field and the section menu stay on screen for
            // every section — including Collections. (They used to live
            // inside `videoGridHome` only, so tapping Collections made
            // the whole menu vanish and there was no way back.)
            VStack(spacing: 0) {
                searchFieldView
                sectionMenu
                if viewModel.selectedSection == .collections && !viewModel.isSearching {
                    collectionsContent
                } else {
                    videoGridContent
                }
            }
            .preferredColorScheme(.dark)
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

    /// Search field (always on screen, above the section menu).
    private var searchFieldView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("Search title, caption, @username", text: $viewModel.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// The video grid content (loading / empty / grid) for the Tất cả,
    /// Reels, and Bài viết sections, and for search results. The search
    /// field and section menu live in `content` (shared by all sections).
    /// Tapping a video opens it in the full-screen feed viewer.
    private var videoGridContent: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView("Loading…")
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.items.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button("Save a link") { showingURLInput = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                videoGrid
            }
        }
    }

    /// The 3-column video grid (TikTok profile style): 9:16 cells,
    /// 2pt gaps, rounded corners. The last cell loads the next page
    /// when it appears (waterfall); pull-to-refresh reloads.
    /// Tapping a cell opens the full-screen feed viewer at that video.
    /// Long-pressing a cell opens the native iOS context menu (Save to
    /// Photos / Share / Favorite / Add to Album / Delete) — the cell
    /// lifts as the menu's preview. In multi-select mode a tap toggles
    /// the cell's selection instead, and the context menu is off.
    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: videoColumns, spacing: 2) {
                ForEach(viewModel.items) { item in
                    VideoGridCell(
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
            }
        }
        .refreshable {
            await viewModel.fetch()
        }
    }

    /// True when the home is showing a video grid (all/reels/posts,
    /// or search results) — the only place multi-select applies.
    /// The Collections section shows collection cards, not videos.
    private var showsVideoGrid: Bool {
        viewModel.selectedSection != .collections || viewModel.isSearching
    }

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

    /// Menu bar: Tất cả / Reels / Bài viết / Collections. Selected
    /// is a white capsule with black text (TikTok's selected tab);
    /// the rest are white text on a subtle dark capsule.
    private var sectionMenu: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibrarySection.allCases) { section in
                    let selected = viewModel.selectedSection == section
                    Button {
                        Task { await viewModel.selectSection(section) }
                    } label: {
                        Text(section.title)
                            .font(.subheadline)
                            .fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selected ? Color.white : Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// Collections: the user's own collections ("My collections", with
    /// a New card) on top, then the per-creator collections below.
    /// Tapping a card opens its videos in a grid; tapping a video
    /// there opens the feed viewer.
    private var collectionsContent: some View {
        Group {
            if viewModel.collections.isEmpty && viewModel.myCollections.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("No collections yet", systemImage: "folder")
                } description: {
                    Text("Save a link and it will appear here grouped by its creator.")
                } actions: {
                    Button("Save a link") { showingURLInput = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("My collections")
                        LazyVGrid(columns: collectionColumns, spacing: 12) {
                            Button {
                                showingNewCollection = true
                            } label: {
                                newCollectionCard
                            }
                            .buttonStyle(.plain)
                            ForEach(viewModel.myCollections) { collection in
                                Button {
                                    selectedMyCollection = collection
                                } label: {
                                    MyCollectionCard(collection: collection)
                                }
                                .buttonStyle(.plain)
                                // The whole square is the tap target:
                                // the card is a transparent Color.clear
                                // with its visible content in an overlay,
                                // so without an explicit content shape
                                // only the overlaid parts register taps.
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal)
                        if !viewModel.collections.isEmpty {
                            sectionHeader("Creators")
                            LazyVGrid(columns: collectionColumns, spacing: 12) {
                                ForEach(viewModel.collections) { collection in
                                    Button {
                                        selectedCollection = collection
                                    } label: {
                                        CollectionCard(collection: collection)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom)
                        }
                    }
                }
                .refreshable {
                    await viewModel.fetchCollections()
                }
                .overlay {
                    if viewModel.isLoading && viewModel.collections.isEmpty && viewModel.myCollections.isEmpty {
                        ProgressView("Loading…")
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    /// Dashed "+" card that opens the "New collection" name alert.
    private var newCollectionCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("New collection")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var emptyTitle: String {
        if viewModel.isSearching { return "No matches" }
        switch viewModel.selectedSection {
        case .reels: return "No reels yet"
        case .posts: return "No posts yet"
        case .all, .collections: return "Nothing saved yet"
        }
    }

    private var emptyIcon: String {
        if viewModel.isSearching { return "magnifyingglass" }
        return "tray"
    }

    private var emptyDescription: String {
        if viewModel.isSearching { return "Nothing saved matches this search yet." }
        switch viewModel.selectedSection {
        case .reels: return "No saved videos yet — save a TikTok or Reels link."
        case .posts: return "No saved photos yet — save a photo post link."
        case .all, .collections: return "Tap + and paste a link from TikTok, Instagram, Threads, X, Facebook, Douyin, or YouTube."
        }
    }
}

/// One collection card (TikTok-style, measured from TikTok's Collections
/// tab): a SQUARE cover (1:1) with the name overlaid at the bottom — the
/// bookmark icon above the name, the lock at bottom-right — and no text
/// or count below the card. Side padding 16, gap 12, corner radius 12.
/// The cover image is forced to fill the square (a 9:16 video frame is
/// centre-cropped, never letterboxed), so the card reads as a square
/// thumbnail exactly like TikTok's.
///
/// Sizing: a plain ZStack with aspectRatio(1) — the cover fills the
/// square, never sizes it. (The v16 Color.clear + overlay pattern made
/// the cards look square but shifted the tap area down by one row in
/// the LazyVGrid: tapping nuocloc7mao opened nanshwesang, tapping
/// @meodidau_ opened nanacat099. The overlay's frame and the card's
/// frame disagreed, so the hit-test landed on the cell below.)
private struct CollectionCard: View {
    let collection: CollectionInfo

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            cover
            // Bottom gradient so the white overlay text stays legible.
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(nameLine)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let handle = handleLine {
                        Text(handle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "lock")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            .padding(12)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The cover, forced to fill the square card (centre-cropped).
    private var cover: some View {
        Group {
            if let coverId = collection.coverItemId {
                AuthenticatedThumbnail(itemId: coverId)
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var nameLine: String {
        if let author = collection.author, !author.isEmpty { return author }
        return collection.displayName
    }

    private var handleLine: String? {
        guard let username = collection.authorUsername, !username.isEmpty else { return nil }
        // When there is no display name, displayName already is @username.
        if collection.author == nil || collection.author?.isEmpty == true { return nil }
        return "(@\(username))"
    }
}

/// One user-created collection card (square, like the per-creator
/// cards): cover thumbnail (or a folder placeholder), name + video
/// count overlaid at the bottom. The cover is forced to fill the
/// square (centre-cropped, never letterboxed), like TikTok's.
/// A plain ZStack with aspectRatio(1) — see CollectionCard: the
/// Color.clear + overlay pattern shifted the tap area down one row.
private struct MyCollectionCard: View {
    let collection: MyCollection

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            cover
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(collection.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(collection.count) video")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(12)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The cover, forced to fill the square card (centre-cropped).
    private var cover: some View {
        Group {
            if let coverId = collection.coverItemId {
                AuthenticatedThumbnail(itemId: coverId)
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// One video cell in the 3-column grid (TikTok profile style): a
/// vertical 9:16 cell with slightly rounded corners, so each cell stays
/// visibly distinct even when consecutive videos look alike. The
/// thumbnail fills the cell (a 9:16 video fits exactly; anything wider
/// is centre-cropped, like TikTok) and is clipped to the cell, so
/// nothing overflows. Badge bottom-left (play + view count, or duration),
/// a spinner while pending, and a red dot when ingest failed.
///
/// NOTE: used by the home grid and by the collection detail page
/// (a per-creator overview, like a TikTok profile grid). Tapping a
/// cell opens the video in the full-screen feed viewer. Long-press
/// opens the native iOS context menu (Save to Photos / Share /
/// Favorite / Add to Album / Delete), attached by the parent — the
/// cell itself has no long-press gesture. A red heart at the
/// top-right marks a favorited video.
///
/// Tap is on this cell and the long-press menu is the native
/// `.contextMenu`, attached by the parent (no Button wrapper in the
/// parent): a Button around the cell swallowed the tap once a
/// long-press gesture was added inside it (v16 regression — cells
/// stopped opening the feed). With tap on the cell and the context
/// menu on the same view, SwiftUI resolves tap vs long-press
/// correctly.
struct VideoGridCell: View {
    let item: Item
    /// Multi-select: when true the cell shows a selection circle
    /// (top-left) and a tap toggles selection (the parent's onTap
    /// decides). The long-press menu is the native `.contextMenu`,
    /// attached by the parent (LibraryView / CollectionDetailView) —
    /// the cell itself has no long-press gesture any more.
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AuthenticatedThumbnail(item: item)
                .aspectRatio(9 / 16, contentMode: .fill)
                .clipped()
            if item.status == .pending {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .tint(.white)
                }
            }
            if let badge = badgeText, item.status == .ready {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text(badge)
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                .padding(6)
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .onTapGesture {
            onTap?()
        }
    }

    private var badgeText: String? {
        item.formattedViewCount ?? item.formattedDuration
    }
}

/// Bottom bar shown in multi-select mode: Select All / Deselect All
/// and Delete (N). Shared by the home grid and the collection grids.
/// `totalCount` is the number of videos currently loaded in the grid
/// (the grid pages, so Select All covers the loaded set).
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

/// Long-press menu for a video in a grid (home, a collection, My
/// collection): Favorite, Add to Collection, Delete — the same three
/// actions as the feed menu minus Copy/Download/Playback speed (there
/// is no player in a grid). The Add to Collection picker is the
/// shared AddToCollectionPickerView. `onRemoveFromCollection` adds a
/// fourth button (My collections only — it removes the video from
/// that collection, it stays saved). The parent presents this as a
/// sheet and handles the delete confirmation (the menu only reports
/// the tap, like the feed menu does).
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
/// Actions are closures so each grid (home, per-creator collection,
/// My collection) wires its own sheets/dialogs. The menu is empty
/// while multi-select is on (long-press is off there; a tap toggles
/// selection instead). `onRemoveFromCollection` is only set by the My
/// collection grid, where a video can leave the collection without
/// being deleted.
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
