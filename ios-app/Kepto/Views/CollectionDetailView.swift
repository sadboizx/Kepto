import SwiftUI
import UIKit

/// One collection's videos: a square grid (Photos style, 2 or 3 columns
/// by screen width), newest first. Tapping a video opens it in the full-screen feed
/// (swipe up/down for the next video in this collection). Pull-to-refresh
/// reloads the collection. (No status filter: the All/Pending/Ready/Failed
/// picker was removed — a collection just shows all its videos.)
struct CollectionDetailView: View {
    let collection: CollectionInfo
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [Item] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// The video the feed opens on (nil = feed closed).
    @State private var feedStartItem: Item?
    /// The video the context menu's "Add to Album" opened the picker
    /// for (nil = picker closed).
    @State private var itemForAlbumPicker: Item?
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// The video awaiting delete confirmation from the grid menu.
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false
    /// Multi-select mode for bulk delete (same pattern as the home
    /// grid): tap toggles selection, bottom bar has Select All /
    /// Delete (N).
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showingBulkDeleteConfirmation = false
    /// Presents the Settings sheet from the "…" menu.
    @State private var showingSettings = false

    /// Detail-grid columns: 2 on narrow screens, 3 on wide ones
    /// (spec: "2 hoặc 3 cột tùy kích thước màn hình"). iPhone 12 Pro
    /// Max (428pt) gets 3; iPhone SE / 12 (375–390pt) get 2.
    private var columns: [GridItem] { albumGridColumns() }

    var body: some View {
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
                    }
                }
                if nextCursor != nil {
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView()
                        } else {
                            Button("Load more") {
                                Task { await loadMore() }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle(collection.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Transparent status bar / nav bar (see AlbumsView).
        .toolbarBackground(.hidden, for: .navigationBar)
        // Custom white back button: .tint(.white) did NOT recolor the
        // system back button (still blue, v41), so hide it and draw
        // our own "< Albums" in white. The swipe-back gesture still
        // works (it is a navigation-controller gesture, not the
        // button).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Albums")
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    // Photos style: "Select" is a dark pill with
                    // white footnote text, like the Library tab.
                    Button {
                        toggleSelecting()
                    } label: {
                        Text(isSelecting ? "Cancel" : "Select")
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button { showingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        // Photos style: a dark circle with a white
                        // ellipsis, like the Library tab.
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .accessibilityLabel("More options")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
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
                ProgressView("Loading…")
            } else if items.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No videos yet", systemImage: "tray")
                } description: {
                    Text("Videos saved from \(collection.displayName) will appear here.")
                }
            }
        }
        .alert("Kepto", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .navigationDestination(item: $feedStartItem) { startItem in
            FeedView(
                items: $items,
                startItemId: startItem.id,
                onNearEnd: { await loadMore() }
            )
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
    }

    /// Bottom bar in multi-select mode (see LibraryView).
    private var selectionBar: some View {
        SelectionActionBar(
            selectedCount: selectedIDs.count,
            totalCount: items.count,
            onSelectAll: { selectAll() },
            onDelete: { showingBulkDeleteConfirmation = true }
        )
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

    /// Select all videos currently loaded in this collection grid.
    private func selectAll() {
        if selectedIDs.count == items.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(items.map(\.id))
        }
    }

    /// Delete every selected video (sequential, reusing the single
    /// delete), then exit multi-select mode. A failure leaves the
    /// video in the grid and is reported.
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
            errorMessage = "Đã xóa \(targets.count - failures) video, \(failures) video lỗi."
        }
    }

    /// Delete the video pending confirmation from the grid menu.
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
    /// video. (No sheet to dismiss first, unlike the old bottom-sheet
    /// menu — the confirmation can appear immediately.)
    private func requestGridDelete(_ item: Item) {
        itemPendingDelete = item
        showingDeleteConfirmation = true
    }

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

    private func fetch(reset: Bool) async {
        guard !isLoading && !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (page, cursor) = try await viewModel.listCollection(
                authorUsername: collection.id,
                status: nil,
                limit: 50,
                cursor: reset ? nil : nextCursor
            )
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
            let (page, cursor) = try await viewModel.listCollection(
                authorUsername: collection.id,
                status: nil,
                limit: 50,
                cursor: nextCursor
            )
            items.append(contentsOf: page)
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// One user-created collection's videos: a square grid (Photos style,
/// 2 or 3 columns by screen width), newest-added first. Tapping a video opens it in the full-screen
/// feed (swipe up/down for the next video in this collection).
/// Long-press a cell (0.25s) opens the grid menu (Favorite / Add to
/// Collection / Remove from collection / Delete). The toolbar trash
/// button deletes the whole collection (its videos stay saved).
struct MyCollectionDetailView: View {
    let collection: MyCollection
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [Item] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// The video the feed opens on (nil = feed closed).
    @State private var feedStartItem: Item?
    /// The video the context menu's "Add to Album" opened the picker
    /// for (nil = picker closed).
    @State private var itemForAlbumPicker: Item?
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// The video awaiting delete confirmation from the grid menu.
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false
    @State private var showingDeleteCollection = false
    @State private var removeError: String?
    /// Multi-select mode for bulk delete (same pattern as the home
    /// grid and the per-creator collection).
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showingBulkDeleteConfirmation = false

    /// Detail-grid columns: 2 on narrow screens, 3 on wide ones
    /// (spec: "2 hoặc 3 cột tùy kích thước màn hình"). iPhone 12 Pro
    /// Max (428pt) gets 3; iPhone SE / 12 (375–390pt) get 2.
    private var columns: [GridItem] { albumGridColumns() }

    var body: some View {
        ScrollView {
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
                            onRemoveFromCollection: { item in
                                Task { await removeFromCollection(item) }
                            }
                        )
                    }
                }
            }
            if nextCursor != nil {
                HStack {
                    Spacer()
                    if isLoadingMore {
                        ProgressView()
                    } else {
                        Button("Load more") {
                            Task { await loadMore() }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        // Transparent status bar / nav bar (see AlbumsView).
        .toolbarBackground(.hidden, for: .navigationBar)
        // Custom white back button: .tint(.white) did NOT recolor the
        // system back button (still blue, v41), so hide it and draw
        // our own "< Albums" in white. The swipe-back gesture still
        // works (it is a navigation-controller gesture, not the
        // button).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Albums")
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    // Photos style: "Select" is a dark pill with
                    // white footnote text, like the Library tab.
                    Button {
                        toggleSelecting()
                    } label: {
                        Text(isSelecting ? "Cancel" : "Select")
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // The trash button is gone — deleting the whole
                    // collection lives in the "…" menu instead, so it
                    // cannot be hit by accident next to Select. Hidden
                    // while selecting videos, like the trash was.
                    if !isSelecting {
                        Menu {
                            Button(role: .destructive) {
                                showingDeleteCollection = true
                            } label: {
                                Label("Delete collection", systemImage: "trash")
                            }
                        } label: {
                            // Photos style: a dark circle with a white
                            // ellipsis, like the Library tab.
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                                .accessibilityLabel("More options")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
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
                ProgressView("Loading…")
            } else if items.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No videos yet", systemImage: "folder")
                } description: {
                    Text("Add a video from the feed's long-press menu.")
                }
            }
        }
        .alert("Kepto", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Remove failed", isPresented: .constant(removeError != nil)) {
            Button("OK") { removeError = nil }
        } message: {
            Text(removeError ?? "")
        }
        .confirmationDialog("Delete collection \"\(collection.name)\"?",
                            isPresented: $showingDeleteCollection,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteCollection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The videos in it stay saved in the library.")
        }
        .navigationDestination(item: $feedStartItem) { startItem in
            FeedView(
                items: $items,
                startItemId: startItem.id,
                onNearEnd: { await loadMore() }
            )
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
    }

    /// Bottom bar in multi-select mode (see LibraryView).
    private var selectionBar: some View {
        SelectionActionBar(
            selectedCount: selectedIDs.count,
            totalCount: items.count,
            onSelectAll: { selectAll() },
            onDelete: { showingBulkDeleteConfirmation = true }
        )
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

    /// Select all videos currently loaded in this collection grid.
    private func selectAll() {
        if selectedIDs.count == items.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(items.map(\.id))
        }
    }

    /// Delete every selected video (sequential, reusing the single
    /// delete), then exit multi-select mode. A failure leaves the
    /// video in the grid and is reported.
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
            errorMessage = "Đã xóa \(targets.count - failures) video, \(failures) video lỗi."
        }
    }

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
            items.removeAll { $0.id == target.id }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func fetch(reset: Bool) async {
        guard !isLoading && !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (page, cursor) = try await viewModel.listMyCollectionItems(
                collectionId: collection.id,
                limit: 50,
                cursor: reset ? nil : nextCursor
            )
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
            let (page, cursor) = try await viewModel.listMyCollectionItems(
                collectionId: collection.id,
                limit: 50,
                cursor: nextCursor
            )
            items.append(contentsOf: page)
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Removes a video from this collection only — the item itself
    /// stays saved in the library.
    private func removeFromCollection(_ item: Item) async {
        do {
            try await viewModel.removeItemFromMyCollection(collectionId: collection.id, item: item)
            items.removeAll { $0.id == item.id }
        } catch {
            removeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteCollection() async {
        do {
            try await viewModel.deleteMyCollection(id: collection.id)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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

/// Which built-in album the Albums tab's detail page shows.
enum AlbumKind: String, Hashable {
    case recents, favorites

    var title: String {
        switch self {
        case .recents: return "Recents"
        case .favorites: return "Favorites"
        }
    }
}

/// Which album section the "See All" page shows (Photos Albums
/// style: each section header has a "See All" button on the right).
enum AlbumSection: String, Hashable {
    case myAlbums
    case creators
}

/// One album card's identity, so the horizontal 2-row grids and the
/// "See All" full grid can share the same card list and selection.
enum AlbumCard: Hashable {
    case kind(AlbumKind)
    case myCollection(MyCollection)
    case creator(CollectionInfo)
}

/// Albums: the Photos-style Albums tab. Two sections, each a
/// sideways-scrolling 2-row grid of square album cards (cover +
/// name + count below, like Photos iOS 17.4), with a "See All"
/// button on the right of each header:
///  - "My Albums": Recents (all saved items), Favorites (hearted
///    items), then the user's own collections.
///  - "Creators": one card per TikTok creator whose collection was
///    saved (the old per-creator list, now in its own section —
///    Photos' "Shared Albums" slot, renamed, since Kepto has no
///    sharing).
/// A blue "+" at the top-left creates a new album (a user-created
/// collection). Tapping a card opens its videos in a square grid;
/// tapping a video there opens the feed. "See All" opens the whole
/// section as a 2-column grid. Dark mode is forced at the app root
/// (KeptoTabView).
struct AlbumsView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel
    /// "New collection" name alert (from the "+" button).
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var saveNotice: String?
    /// Presents the Settings sheet from the "…" menu.
    @State private var showingSettings = false
    /// The section whose "See All" page is open (nil = closed).
    @State private var seeAllSection: AlbumSection?
    /// The collection whose detail page is open (nil = closed).
    /// Navigation is a Button + navigationDestination, NOT an inline
    /// NavigationLink in the LazyVGrid: inline links in a lazy grid
    /// are flaky on iOS 17 (some cards simply never navigate).
    @State private var selectedCollection: CollectionInfo?
    @State private var selectedMyCollection: MyCollection?
    @State private var selectedAlbumKind: AlbumKind?

    /// 2-column album grid (Photos Albums tab): 12pt gaps.
    private let albumColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    albumSection(title: "My Albums", cards: myAlbumCards) {
                        seeAllSection = .myAlbums
                    }
                    albumSection(title: "Creators", cards: creatorCards) {
                        seeAllSection = .creators
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .navigationTitle("Albums")
            // Transparent status bar / nav bar: the sections show
            // through under the status bar and the title, no solid
            // band.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingNewCollection = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The "…" menu lives on every tab except the
                    // Player: Clipboard, then Settings.
                    Menu {
                        Button {
                            Task {
                                if let notice = await viewModel.saveFromClipboard() {
                                    saveNotice = notice
                                } else {
                                    saveNotice = "Không có link trên clipboard."
                                }
                            }
                        } label: {
                            Label("Clipboard", systemImage: "doc.on.clipboard")
                        }
                        Button { showingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .accessibilityLabel("More options")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .navigationDestination(item: $selectedCollection) { collection in
                CollectionDetailView(collection: collection)
            }
            .navigationDestination(item: $selectedMyCollection) { collection in
                MyCollectionDetailView(collection: collection)
            }
            .navigationDestination(item: $selectedAlbumKind) { kind in
                AlbumItemsView(kind: kind)
            }
            .navigationDestination(item: $seeAllSection) { section in
                ScrollView {
                    LazyVGrid(columns: albumColumns, spacing: 16) {
                        ForEach(section == .myAlbums ? myAlbumCards : creatorCards, id: \.self) { card in
                            Button { select(card) } label: {
                                cardView(for: card)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .navigationTitle(section == .myAlbums ? "My Albums" : "Creators")
            }
            .task {
                await viewModel.fetchCollections()
                await viewModel.fetchStats()
                if viewModel.items.isEmpty {
                    await viewModel.fetch()
                }
            }
            .refreshable {
                await viewModel.fetchCollections()
                await viewModel.fetchStats()
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
            .alert("Kepto", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    /// "My Albums" cards: Recents, Favorites, then the user's own
    /// collections.
    private var myAlbumCards: [AlbumCard] {
        [.kind(.recents), .kind(.favorites)] + viewModel.myCollections.map { .myCollection($0) }
    }

    /// "Creators" cards: one per TikTok creator whose collection
    /// was saved.
    private var creatorCards: [AlbumCard] {
        viewModel.collections.map { .creator($0) }
    }

    /// Two rows for the horizontal grids (Photos Albums style: each
    /// section scrolls sideways and is at most 2 rows tall).
    private var albumRows: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    /// Card width in the horizontal grids: two full cards plus a
    /// peek of the next one fit on screen, like Photos.
    private var albumCardWidth: CGFloat {
        (UIScreen.main.bounds.width - 44) / 2
    }

    /// One section (My Albums / Creators): a header with a "See All"
    /// button on the right, then a sideways-scrolling 2-row grid of
    /// album cards. Swipe sideways to see more albums.
    private func albumSection(title: String, cards: [AlbumCard], onSeeAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Spacer()
                Button("See All", action: onSeeAll)
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: albumRows, spacing: 12) {
                    ForEach(cards, id: \.self) { card in
                        Button { select(card) } label: {
                            cardView(for: card)
                                .frame(width: albumCardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// The card view for one album (square cover + name + count
    /// below).
    private func cardView(for card: AlbumCard) -> AlbumCardView {
        switch card {
        case .kind(.recents):
            return AlbumCardView(name: "Recents", count: recentsCount, coverItemId: viewModel.items.first?.id)
        case .kind(.favorites):
            return AlbumCardView(name: "Favorites", count: favoritesCount, coverItemId: viewModel.items.first(where: { $0.isFavorite })?.id, showsHeart: true)
        case .myCollection(let collection):
            // User albums show in lowercase; Recents / Favorites
            // (the .kind cases above) keep their Title Case.
            return AlbumCardView(name: collection.name.lowercased(), count: collection.count, coverItemId: collection.coverItemId)
        case .creator(let collection):
            return AlbumCardView(name: collection.displayName.lowercased(), count: collection.count, coverItemId: collection.coverItemId)
        }
    }

    /// Opens the tapped album's detail page.
    private func select(_ card: AlbumCard) {
        switch card {
        case .kind(let kind):
            selectedAlbumKind = kind
        case .myCollection(let collection):
            selectedMyCollection = collection
        case .creator(let collection):
            selectedCollection = collection
        }
    }

    /// Recents count: the real total from /api/stats when available,
    /// else the number of items loaded so far.
    private var recentsCount: Int {
        viewModel.libraryStats?.total ?? viewModel.items.count
    }

    /// Favorites count: from /api/stats when available, else the
    /// favorited items among the loaded ones.
    private var favoritesCount: Int {
        viewModel.libraryStats?.favorites ?? viewModel.items.filter(\.isFavorite).count
    }
}

/// One album card (Photos Albums style): a SQUARE cover (1:1,
/// centre-cropped, slightly rounded corners) with the name and the
/// item count BELOW the card — not overlaid on it. (The old
/// TikTok-style cards overlaid the name on the cover; Photos puts
/// the text underneath.) `showsHeart` adds the white heart Photos
/// shows on the Favorites album cover.
private struct AlbumCardView: View {
    let name: String
    let count: Int
    let coverItemId: String?
    var showsHeart: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let coverItemId {
                        AspectThumbnail(itemId: coverItemId)
                    } else {
                        Color(.systemGray5)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if showsHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                        .padding(10)
                }
            }
            // Album names are NOT bold (Photos style: regular
            // weight). The name is shown as given — Recents and
            // Favorites keep their Title Case, while My collections
            // and creator albums are lowercased at the call site.
            Text(name)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // The tappable region is exactly this card's bounds (see
        // PhotosGridCell): a tap on the bottom edge must open this
        // album, not the one below it.
        .contentShape(Rectangle())
    }
}

/// One built-in album's videos (Recents = all saved items,
/// Favorites = hearted items): a square grid (Photos style, 2 or 3
/// columns by screen width), newest first. Tapping a video opens it
/// in the full-screen feed (swipe up/down for the next video in
/// this album). Pull-to-refresh reloads. Long-press a cell opens
/// the native iOS context menu (Save to Photos / Share / Favorite /
/// Add to Album / Delete); Select mode bulk-deletes like the other
/// grids.
struct AlbumItemsView: View {
    let kind: AlbumKind
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [Item] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// The video the feed opens on (nil = feed closed).
    @State private var feedStartItem: Item?
    /// The video the context menu's "Add to Album" opened the picker
    /// for (nil = picker closed).
    @State private var itemForAlbumPicker: Item?
    /// A downloaded file ready for the iOS share sheet (nil = closed).
    @State private var shareFile: ShareFile?
    /// The video awaiting delete confirmation from the grid menu.
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false
    /// Multi-select mode for bulk delete (same pattern as the other
    /// grids): tap toggles selection, bottom bar has Select All /
    /// Delete (N).
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showingBulkDeleteConfirmation = false
    /// Presents the Settings sheet from the "…" menu.
    @State private var showingSettings = false

    private var columns: [GridItem] { albumGridColumns() }

    var body: some View {
        ScrollView {
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
                        Button("Load more") {
                            Task { await loadMore() }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        // Transparent status bar / nav bar (see AlbumsView).
        .toolbarBackground(.hidden, for: .navigationBar)
        // Custom white back button: .tint(.white) did NOT recolor the
        // system back button (still blue, v41), so hide it and draw
        // our own "< Albums" in white. The swipe-back gesture still
        // works (it is a navigation-controller gesture, not the
        // button).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Albums")
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    // Photos style: "Select" is a dark pill with
                    // white footnote text, like the Library tab.
                    Button {
                        toggleSelecting()
                    } label: {
                        Text(isSelecting ? "Cancel" : "Select")
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button { showingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        // Photos style: a dark circle with a white
                        // ellipsis, like the Library tab.
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .accessibilityLabel("More options")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
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
                ProgressView("Loading…")
            } else if items.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No videos yet", systemImage: "tray")
                } description: {
                    Text(kind == .favorites ? "Tap the heart on a video to add it to Favorites." : "Videos you save will appear here.")
                }
            }
        }
        .alert("Kepto", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .navigationDestination(item: $feedStartItem) { startItem in
            FeedView(
                items: $items,
                startItemId: startItem.id,
                onNearEnd: { await loadMore() }
            )
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
    }

    /// Bottom bar in multi-select mode (see LibraryView).
    private var selectionBar: some View {
        SelectionActionBar(
            selectedCount: selectedIDs.count,
            totalCount: items.count,
            onSelectAll: { selectAll() },
            onDelete: { showingBulkDeleteConfirmation = true }
        )
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

    /// Select all videos currently loaded in this album grid.
    private func selectAll() {
        if selectedIDs.count == items.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(items.map(\.id))
        }
    }

    /// Delete every selected video (sequential, reusing the single
    /// delete), then exit multi-select mode. A failure leaves the
    /// video in the grid and is reported.
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
            errorMessage = "Đã xóa \(targets.count - failures) video, \(failures) video lỗi."
        }
    }

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
    /// video. (No sheet to dismiss first, unlike the old bottom-sheet
    /// menu — the confirmation can appear immediately.)
    private func requestGridDelete(_ item: Item) {
        itemPendingDelete = item
        showingDeleteConfirmation = true
    }

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

    private func fetch(reset: Bool) async {
        guard !isLoading && !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (page, cursor): ([Item], String?)
            switch kind {
            case .recents:
                (page, cursor) = try await viewModel.listAll(
                    limit: 50,
                    cursor: reset ? nil : nextCursor
                )
            case .favorites:
                (page, cursor) = try await viewModel.listFavorites(
                    limit: 50,
                    cursor: reset ? nil : nextCursor
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
            switch kind {
            case .recents:
                (page, cursor) = try await viewModel.listAll(limit: 50, cursor: nextCursor)
            case .favorites:
                (page, cursor) = try await viewModel.listFavorites(limit: 50, cursor: nextCursor)
            }
            items.append(contentsOf: page)
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
