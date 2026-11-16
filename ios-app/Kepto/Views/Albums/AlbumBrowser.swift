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
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// Short notice from a bulk action ("Đã lưu 3 vào Photos.").
    @State private var notice: String?
    /// The item the feed opens on (nil = feed closed).
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

    var body: some View {
        collectionWithNavigation
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

    /// Navigation + sheets over the grid: the feed destination, the
    /// slideshow cover, and the four sheets (Add to Album picker,
    /// single share, bulk share, Add to Album sheet). A separate
    /// property so the compiler type-checks it apart from `body`.
    private var collectionWithNavigation: some View {
        collectionWithAlerts
            .navigationDestination(item: $feedStartItem) { startItem in
                PhotoDetailView(
                    items: $items,
                    startItemId: startItem.id,
                    onNearEnd: { await loadMore() },
                    title: title,
                    sourceFrame: feedStartFrame
                )
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
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
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
            .alert("Kepto", isPresented: .constant(notice != nil)) {
                Button("OK") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Transparent status bar / nav bar (see AlbumsView).
            .toolbarBackground(.hidden, for: .navigationBar)
            // The system back button ("< Albums") is white via
            // .tint(.primary) on the AlbumsView NavigationStack (the tint
            // comes from the stack, not the pushed view). It stays the
            // system button so the swipe-back gesture works.
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.cancel) { exitSelectionMode() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selectedIDs.count == items.count ? L10n.deselectAll : L10n.selectAll) {
                            if selectedIDs.count == items.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(items.map(\.id))
                            }
                        }
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
                await fetch(reset: true)
            }
            .overlay {
                if isLoading && items.isEmpty {
                    ProgressView(L10n.loading)
                } else if items.isEmpty && !isLoading {
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
    private var collectionGrid: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(items) { item in
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
                            if item.id == items.last?.id {
                                Task { await loadMore() }
                            }
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
        // The cells report their global frames (see
        // `PhotosGridCell`): keep them in the cache so a tap can hand
        // the tapped cell's frame to the viewer for its
        // shrink-to-thumbnail dismiss.
        .onPreferenceChange(CellFramePreferenceKey.self) { frames in
            cellFrameCache.frames.merge(frames) { _, new in new }
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

    /// Bottom bar in multi-select mode: Photos' SelectBottomBar
    /// (Share / Favorite / Add / Delete) + a "More" menu with Save
    /// to Photos and Slideshow. (Photos' Hide / Duplicate entries
    /// are dropped — Hide and Duplicate were cut in Q3/Q4.)
    private var selectBar: some View {
        SelectBottomBar(
            enabled: !selectedIDs.isEmpty,
            onShare: { Task { await shareSelection() } },
            onFavorite: { Task { await favoriteSelection() } },
            onAdd: { showingAddToAlbum = true },
            onDelete: { showingBulkDeleteConfirmation = true }
        ) {
            Menu {
                Button { Task { await saveSelectionToPhotos() } } label: {
                    Label(L10n.saveToPhotos, systemImage: "arrow.down.to.line")
                }
                Button { presentSlideshow() } label: {
                    Label(L10n.slideshow, systemImage: "play.rectangle")
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle").font(.system(size: 20))
                    Text(L10n.more).font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
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
        let resolved = items.filter { selectedIDs.contains($0.id) }
        guard !resolved.isEmpty else { return }
        slideshowItems = resolved
        showingSlideshow = true
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
            items = reset ? page : items + page
            nextCursor = cursor
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
            items.append(contentsOf: page)
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Single-item actions (context menu)

    /// Context menu "Save to Photos": download the item and save it
    /// to the Photos library. Failures show in the error alert.
    private func saveToPhotos(_ item: Item) {
        Task {
            do {
                try await viewModel.saveToPhotos(item: item)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            notice = L10n.shareDownloadFailed
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
            notice = L10n.savedToPhotos(saved)
        } else {
            notice = L10n.savedToPhotosPartial(saved, failed)
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
