import Foundation
import SwiftUI

/// Owns the library screen state. Cloud-only: items live in D1 behind the
/// Worker API; nothing is cached on disk. The home screen is collections
/// (one per creator username, like TikTok's Collections tab); search shows
/// a flat grid of matching items. Pull-to-refresh and search both
/// re-fetch from the server.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// Search results (flat list), used only while the user is searching.
    @Published private(set) var items: [Item] = []
    /// Collections for the home screen (one per creator username).
    @Published private(set) var collections: [CollectionInfo] = []
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

    /// Collections for the home screen. Called on appear and on
    /// pull-to-refresh, and after a save (a new username may appear).
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
    }

    /// First page of search results. Called on pull-to-refresh and whenever
    /// the search text changes (debounced by the view).
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
                limit: 50
            )
            items = page
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Next page of search results using the backend's keyset cursor.
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
    /// can show "already saved" for a duplicate; the collections refresh
    /// to include the new item.
    func save(url: String) async -> SaveResult? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let result = try await api.save(url: url)
            await fetchCollections()
            if isSearching { await fetch() }
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

    /// Refresh one item in place (used after returning from the detail view,
    /// e.g. a pending item may have become ready).
    func refreshItem(_ item: Item) async {
        guard let api else { return }
        guard let updated = try? await api.getItem(id: item.id) else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = updated
        }
    }
}
