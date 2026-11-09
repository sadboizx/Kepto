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
                        Button {
                            feedStartItem = item
                        } label: {
                            VideoGridCell(item: item)
                        }
                        .buttonStyle(.plain)
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
/// Long-press a cell (context menu) to remove that video from the
/// collection — it stays saved in the library. The toolbar trash
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
                    Button {
                        feedStartItem = item
                    } label: {
                        VideoGridCell(item: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await removeFromCollection(item) }
                        } label: {
                            Label("Remove from collection", systemImage: "folder.badge.minus")
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
