import Foundation
import SwiftUI

/// Owns the library screen state. Cloud-only: items live in D1 behind the
/// Worker API; nothing is cached on disk. Pull-to-refresh and search both
/// re-fetch from the server.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedPlatform: Platform?
    @Published var selectedStatus: ItemStatus?

    /// The configured API client, or nil until the user enters a Worker URL
    /// and API key in Settings. Rebuilt by `reloadConfig()`.
    @Published private(set) var api: KeptoAPI?

    private var nextCursor: String?
    private var isFetching = false

    var isConfigured: Bool { api != nil }

    var hasMore: Bool { nextCursor != nil }

    init() {
        reloadConfig()
    }

    /// Re-read the Worker URL (UserDefaults) and API key (Keychain).
    /// Called on launch and after Settings is dismissed.
    func reloadConfig() {
        api = KeptoAPI.configured()
    }

    /// First page. Called on appear, on pull-to-refresh, and whenever the
    /// search text, platform filter, or status filter changes.
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
                platform: selectedPlatform,
                status: selectedStatus,
                query: searchText,
                limit: 50
            )
            items = page
            nextCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Next page using the backend's keyset cursor.
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
                platform: selectedPlatform,
                status: selectedStatus,
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

    /// Save a pasted link. Returns the new pending item on success so the
    /// Save sheet can show it; the list refreshes to include it.
    func save(url: String) async -> Item? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let item = try await api.save(url: url)
            await fetch()
            return item
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Delete an item on the server (R2 objects + D1 row), then drop it
    /// from the list. Throws so the detail view can show the failure.
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
