import Foundation
import SwiftUI

/// The home menu sections: all saved items, video-only (Reels),
/// image-only posts (Bài viết), and the per-creator collections.
/// "Âm thanh" is intentionally NOT a section: audio is stored inside
/// each saved video, not as separate items, so there is nothing to list.
enum LibrarySection: String, CaseIterable, Identifiable {
    case all, reels, posts, collections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tất cả"
        case .reels: return "Reels"
        case .posts: return "Bài viết"
        case .collections: return "Collections"
        }
    }

    /// Backend `media` filter for the section (nil = no filter).
    var mediaFilter: String? {
        switch self {
        case .reels: return "video"
        case .posts: return "image"
        case .all, .collections: return nil
        }
    }
}

/// Owns the library screen state. Cloud-only: items live in D1 behind the
/// Worker API; nothing is cached on disk. The home screen is a flat grid
/// of all saved items (TikTok-style, 3 columns) with a menu to switch
/// between Tất cả / Reels / Bài viết / Collections; search shows a flat
/// grid of matching items. Pull-to-refresh and search both re-fetch
/// from the server.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// Search results (flat list), used only while the user is searching.
    @Published private(set) var items: [Item] = []
    /// Collections for the home screen (one per creator username).
    @Published private(set) var collections: [CollectionInfo] = []
    /// User-created collections ("My collections").
    @Published private(set) var myCollections: [MyCollection] = []
    /// The selected home menu section.
    @Published var selectedSection: LibrarySection = .all
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    /// A link handed over by the Share Extension (kepto://save?url=...).
    /// The Library opens the Save sheet for it, then clears it.
    @Published var pendingShareURL: String?

    /// The configured API client, or nil until the user enters a Worker URL
    /// and API key in Settings. Rebuilt by `reloadConfig()`.
    @Published private(set) var api: KeptoAPI?

    private var nextCursor: String?
    private var isFetching = false

    var isConfigured: Bool { api != nil }

    var hasMore: Bool { nextCursor != nil }

    /// True while the search field has text (home shows results, not collections).
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init() {
        reloadConfig()
    }

    /// Re-read the Worker URL (UserDefaults) and API key (Keychain).
    /// Called on launch and after Settings is dismissed.
    func reloadConfig() {
        api = KeptoAPI.configured()
    }

    /// Switch home menu section and fetch its content.
    func selectSection(_ section: LibrarySection) async {
        selectedSection = section
        if section == .collections {
            await fetchCollections()
        } else {
            await fetch()
        }
    }

    /// Collections for the home screen. Called on appear and on
    /// pull-to-refresh, and after a save (a new username may appear).
    /// Fetches the per-creator collections and the user-created ("My")
    /// collections independently: if the My-collections endpoint fails
    /// (e.g. migration 0004 has not been applied yet), the per-creator
    /// collections still load.
    func fetchCollections() async {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return
        }
        guard !isFetching else { return }
        isFetching = true
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            isFetching = false
        }
        do {
            collections = try await api.collections()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Quiet: a failure here must not wipe the per-creator list above.
        if let mine = try? await api.myCollections() {
            myCollections = mine
        }
    }

    /// Create a user-created collection. Returns it on success so the
    /// caller can add the current video to it right away.
    func createMyCollection(name: String) async -> MyCollection? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let created = try await api.createMyCollection(name: name)
            myCollections.insert(created, at: 0)
            return created
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Quiet refresh of the user-created collections only (used by the
    /// feed's "Add to collection" picker, which may open before the
    /// Collections section was ever visited).
    func fetchMyCollections() async {
        guard let api else { return }
        if let mine = try? await api.myCollections() {
            myCollections = mine
        }
    }

    /// Add a video to a user-created collection. Returns true when it
    /// was newly added, false when it was already there, nil on failure
    /// (the error surfaces through `errorMessage`).
    func addItemToMyCollection(collectionId: String, item: Item) async -> Bool? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let added = try await api.addItemToMyCollection(collectionId: collectionId, itemId: item.id)
            if let mine = try? await api.myCollections() {
                myCollections = mine
            }
            return added
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// One page of a user-created collection's items (used by
    /// MyCollectionDetailView). Throws so the detail view can show it.
    func listMyCollectionItems(collectionId: String,
                               limit: Int = 50,
                               cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        guard let api else { throw KeptoAPIError.notConfigured }
        return try await api.myCollectionItems(collectionId: collectionId, limit: limit, cursor: cursor)
    }

    /// Remove a video from a user-created collection (the item itself
    /// stays saved in the library). Throws so the caller can show it.
    func removeItemFromMyCollection(collectionId: String, item: Item) async throws {
        guard let api else { throw KeptoAPIError.notConfigured }
        try await api.removeItemFromMyCollection(collectionId: collectionId, itemId: item.id)
    }

    /// Delete a user-created collection (its videos stay saved).
    /// Throws so the caller can show the failure.
    func deleteMyCollection(id: String) async throws {
        guard let api else { throw KeptoAPIError.notConfigured }
        try await api.deleteMyCollection(id: id)
        myCollections.removeAll { $0.id == id }
    }

    /// First page of the current section's items (or search results
    /// while searching — search ignores the section filter). Called on
    /// pull-to-refresh and whenever the search text changes (debounced
    /// by the view).
    func fetch() async {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return
        }
        guard !isFetching else { return }
        isFetching = true
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            isFetching = false
        }
        do {
            let (page, cursor) = try await api.list(
                query: searchText,
                media: isSearching ? nil : selectedSection.mediaFilter,
                limit: 50
            )
            items = page
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Next page using the backend's keyset cursor (same filters as fetch).
    func loadMore() async {
        guard let api, let cursor = nextCursor, !isFetching, !isLoadingMore else { return }
        isFetching = true
        isLoadingMore = true
        defer {
            isLoadingMore = false
            isFetching = false
        }
        do {
            let (page, next) = try await api.list(
                query: searchText,
                media: isSearching ? nil : selectedSection.mediaFilter,
                limit: 50,
                cursor: cursor
            )
            items.append(contentsOf: page)
            nextCursor = next
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One page of a collection's items (used by CollectionDetailView).
    /// `username` is the collection id (or "__unknown__" for the Unknown
    /// collection). Throws so the detail view can show the failure.
    func listCollection(authorUsername: String,
                        status: ItemStatus?,
                        limit: Int = 50,
                        cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        guard let api else { throw KeptoAPIError.notConfigured }
        return try await api.list(
            status: status,
            authorUsername: authorUsername,
            limit: limit,
            cursor: cursor
        )
    }

    /// Save a pasted link. Returns the result on success so the Save sheet
    /// can show "already saved" for a duplicate; the current section
    /// refreshes to include the new item.
    func save(url: String) async -> SaveResult? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let result = try await api.save(url: url)
            if isSearching {
                await fetch()
            } else if selectedSection == .collections {
                await fetchCollections()
            } else {
                await fetch()
            }
            return result
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Save every video in a TikTok Collection. Returns the result on
    /// success so the caller can show how many were new; the current
    /// section refreshes to include the new items.
    func saveCollection(url: String) async -> SaveCollectionResult? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let result = try await api.saveCollection(url: url)
            if isSearching {
                await fetch()
            } else if selectedSection == .collections {
                await fetchCollections()
            } else {
                await fetch()
            }
            return result
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Delete an item on the server (R2 objects + D1 row), then drop it
    /// from the search results. Throws so the detail view can show the failure.
    func delete(item: Item) async throws {
        guard let api else { throw KeptoAPIError.notConfigured }
        try await api.delete(id: item.id)
        items.removeAll { $0.id == item.id }
    }

    /// Heart / unheart an item. Updates the item in place (so the grid
    /// and the feed show the new state at once). Returns the updated
    /// item on success; on failure the error surfaces through the
    /// view model's error alert.
    func toggleFavorite(item: Item) async -> Item? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let updated = try await api.setFavorite(id: item.id, favorite: !item.isFavorite)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = updated
            }
            return updated
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Refresh one item in place (used after returning from the detail view,
    /// e.g. a pending item may have become ready).
    func refreshItem(_ item: Item) async {
        guard let api else { return }
        guard let updated = try? await api.getItem(id: item.id) else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = updated
        }
    }

    /// Fetch one item fresh from the server (used by the detail view so
    /// it never shows stale fields — e.g. a preview that only exists
    /// after ingest finished). Returns nil on failure.
    func fetchItem(id: String) async -> Item? {
        guard let api else { return nil }
        return try? await api.getItem(id: id)
    }
}
