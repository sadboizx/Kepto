import SwiftUI

/// One collection's videos: a 3-column portrait grid like a TikTok profile
/// page, newest first. Tapping a video opens it in the full-screen feed
/// (swipe up/down for the next video in this collection). Pull-to-refresh
/// reloads the collection. (No status filter: the All/Pending/Ready/Failed
/// picker was removed — a collection just shows all its videos.)
struct CollectionDetailView: View {
    let collection: CollectionInfo
    @EnvironmentObject private var viewModel: LibraryViewModel

    @State private var items: [Item] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// The video the feed opens on (nil = feed closed).
    @State private var feedStartItem: Item?
    /// The video whose grid long-press menu is open (nil = closed).
    @State private var itemForGridMenu: Item?
    /// The video awaiting delete confirmation from the grid menu.
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(items) { item in
                        VideoGridCell(
                            item: item,
                            onTap: { feedStartItem = item },
                            onLongPress: { itemForGridMenu = $0 }
                        )
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
        .fullScreenCover(item: $feedStartItem) { startItem in
            FeedView(
                items: $items,
                startItemId: startItem.id,
                onNearEnd: { await loadMore() },
                showCloseButton: true
            )
        }
        .sheet(item: $itemForGridMenu) { menuItem in
            GridItemMenuView(
                item: menuItem,
                onToggleFavorite: {
                    Task {
                        if let updated = await viewModel.toggleFavorite(item: menuItem),
                           let idx = items.firstIndex(where: { $0.id == updated.id }) {
                            items[idx] = updated
                        }
                    }
                },
                onDelete: {
                    itemForGridMenu = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        itemPendingDelete = menuItem
                        showingDeleteConfirmation = true
                    }
                },
                onAddedToCollection: { _, _ in }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.black)
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

/// One user-created collection's videos: a 3-column portrait grid,
/// newest-added first. Tapping a video opens it in the full-screen
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
    /// The video whose grid long-press menu is open (nil = closed).
    @State private var itemForGridMenu: Item?
    /// The video awaiting delete confirmation from the grid menu.
    @State private var itemPendingDelete: Item?
    @State private var showingDeleteConfirmation = false
    @State private var showingDeleteCollection = false
    @State private var removeError: String?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    VideoGridCell(
                        item: item,
                        onTap: { feedStartItem = item },
                        onLongPress: { itemForGridMenu = $0 }
                    )
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingDeleteCollection = true
                } label: {
                    Label("Delete collection", systemImage: "trash")
                }
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
        .fullScreenCover(item: $feedStartItem) { startItem in
            FeedView(
                items: $items,
                startItemId: startItem.id,
                onNearEnd: { await loadMore() },
                showCloseButton: true
            )
        }
        .sheet(item: $itemForGridMenu) { menuItem in
            GridItemMenuView(
                item: menuItem,
                onToggleFavorite: {
                    Task {
                        if let updated = await viewModel.toggleFavorite(item: menuItem),
                           let idx = items.firstIndex(where: { $0.id == updated.id }) {
                            items[idx] = updated
                        }
                    }
                },
                onDelete: {
                    itemForGridMenu = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        itemPendingDelete = menuItem
                        showingDeleteConfirmation = true
                    }
                },
                onAddedToCollection: { _, _ in },
                onRemoveFromCollection: {
                    Task { await removeFromCollection(menuItem) }
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.black)
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
