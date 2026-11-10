import Foundation
import Photos
import SwiftUI
import UIKit

/// Owns the library state. Cloud-only: items live in D1 behind the
/// Worker API; nothing is cached on disk. The app is Photos-style now:
/// the Library tab is a flat grid of all saved items (Years / Months /
/// Days / All Photos view modes are a presentation choice in the view,
/// not a server filter), the Albums tab shows per-creator and
/// user-created collections, and the Search tab filters by text or
/// platform. Pull-to-refresh re-fetches from the server.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// All saved items (Library tab, newest first).
    @Published private(set) var items: [Item] = []
    /// Search results (Search tab only), newest first.
    @Published private(set) var searchResults: [Item] = []
    /// Library counts for the Photos-style header ("N Photos,
    /// M Videos") and the Albums tab. Nil until fetched (the
    /// /api/stats endpoint may be unavailable on an older Worker).
    @Published private(set) var libraryStats: LibraryStats?
    /// Collections for the Albums tab (one per creator username).
    @Published private(set) var collections: [CollectionInfo] = []
    /// User-created collections ("My collections").
    @Published private(set) var myCollections: [MyCollection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    /// A link handed over by the Share Extension (kepto://save?url=...).
    /// The app root saves it directly, then clears it.
    @Published var pendingShareURL: String?

    /// The configured API client, or nil until the user enters a Worker URL
    /// and API key in Settings. Rebuilt by `reloadConfig()`.
    @Published private(set) var api: KeptoAPI?

    private var nextCursor: String?
    private var searchCursor: String?
    private var searchQuery: String?
    private var searchPlatform: Platform?
    private var isFetching = false

    var isConfigured: Bool { api != nil }

    var hasMore: Bool { nextCursor != nil }

    /// True while a search (text or platform) has a next page.
    var hasMoreSearchResults: Bool { searchCursor != nil }

    init() {
        reloadConfig()
    }

    /// Re-read the Worker URL (UserDefaults) and API key (Keychain).
    /// Called on launch and after Settings is dismissed.
    func reloadConfig() {
        api = KeptoAPI.configured()
    }

    /// Library counts (GET /api/stats). Quiet: a failure (older
    /// Worker without the endpoint) leaves the counts nil and the
    /// Library simply hides the "N Photos, M Videos" line.
    func fetchStats() async {
        guard let api else { return }
        if let stats = try? await api.stats() {
            libraryStats = stats
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

    /// Download the item's media file and save it to the Photos
    /// library (camera roll) — the context menus' "Save to Photos".
    /// Works for videos and for image posts: the Photos resource type
    /// follows the item's content type (`.photo` for image/*,
    /// `.video` otherwise). Prompts for the Photos "add only"
    /// permission on first use. Throws so the caller can show it.
    func saveToPhotos(item: Item) async throws {
        guard let api else { throw KeptoAPIError.notConfigured }
        let fileURL = try await api.downloadVideoFile(for: item)
        let isImage = item.contentType?.hasPrefix("image/") == true
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard newStatus == .authorized || newStatus == .limited else {
                throw KeptoAPIError.server("Chưa cấp quyền Photos.")
            }
        } else if status != .authorized && status != .limited {
            throw KeptoAPIError.server("Chưa cấp quyền Photos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isImage ? .photo : .video, fileURL: fileURL, options: nil)
        }
    }

    /// Download the item's media file and return its temp URL, for the
    /// iOS share sheet (the context menus' "Share"). The file lives in
    /// the temp directory — present the share sheet promptly, the
    /// system may clean it up. Throws so the caller can show it.
    func shareFileURL(for item: Item) async throws -> URL {
        guard let api else { throw KeptoAPIError.notConfigured }
        return try await api.downloadVideoFile(for: item)
    }

    /// First page of all saved items (Library tab, newest first).
    /// Called on pull-to-refresh and on appear.
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
            let (page, cursor) = try await api.list(limit: 50)
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
            let (page, next) = try await api.list(limit: 50, cursor: cursor)
            items.append(contentsOf: page)
            nextCursor = next
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Search (Search tab): first page of items matching a text query
    /// and/or a platform. Either filter may be nil, but at least one
    /// must be set — the view only calls this with a real query.
    /// Replaces the previous results (the view debounces typing).
    func search(query: String? = nil, platform: Platform? = nil) async {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return
        }
        searchQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        searchPlatform = platform
        do {
            let (page, cursor) = try await api.list(
                platform: platform,
                query: searchQuery,
                limit: 50
            )
            searchResults = page
            searchCursor = cursor
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Next page of the current search (same query / platform).
    func searchMore() async {
        guard let api, let cursor = searchCursor, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let (page, next) = try await api.list(
                platform: searchPlatform,
                query: searchQuery,
                limit: 50,
                cursor: cursor
            )
            searchResults.append(contentsOf: page)
            searchCursor = next
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Clear the search results and filters (Search tab, when the
    /// query is emptied and no category is selected).
    func clearSearch() {
        searchResults = []
        searchCursor = nil
        searchQuery = nil
        searchPlatform = nil
    }

    /// One page of all saved items (used by the Albums tab's Recents
    /// detail). Throws so the detail view can show the failure.
    func listAll(limit: Int = 50,
                 cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        guard let api else { throw KeptoAPIError.notConfigured }
        return try await api.list(limit: limit, cursor: cursor)
    }

    /// One page of favorited items (used by the Albums tab's
    /// Favorites detail). Throws so the detail view can show it.
    func listFavorites(limit: Int = 50,
                       cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        guard let api else { throw KeptoAPIError.notConfigured }
        return try await api.list(favorite: true, limit: limit, cursor: cursor)
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

    /// Save a pasted link. The Worker auto-detects a Collection link,
    /// so this returns either a single video or a whole collection.
    /// After a save the Library and the Albums tab both refresh, so
    /// the new item (and any new creator collection) shows up.
    func save(url: String) async -> SaveOutcome? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let result = try await api.save(url: url)
            await fetch()
            await fetchCollections()
            return result
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Reads the first http(s) URL on the clipboard and saves it
    /// (single video or whole collection, via save(url:)). Returns a
    /// short notice string for the caller to display, or nil when
    /// there is no link on the clipboard (the caller shows its own
    /// "no link" warning then). Shared by the "…" Clipboard action
    /// in every tab (Library, For You, Albums, Search).
    func saveFromClipboard() async -> String? {
        guard let text = UIPasteboard.general.string,
              let url = Self.firstURL(in: text) else { return nil }
        guard let result = await save(url: url.absoluteString) else { return nil }
        switch result {
        case .single(let single):
            return single.duplicate ? "Link này đã lưu trước đó." : "Đã lưu."
        case .collection(let coll):
            var notice = "Đã lưu \(coll.created) video mới"
            if coll.duplicates > 0 { notice += " (\(coll.duplicates) video đã có trước đó)" }
            if coll.capped { notice += " — chỉ lấy 100 video đầu" }
            if let title = coll.title, !title.isEmpty { notice = "Collection “\(title)”: " + notice }
            return notice + "."
        }
    }

    /// The first http(s) URL in a piece of text (clipboard content).
    static func firstURL(in text: String) -> URL? {
        let pattern = "https?://[^\\s\"'<>]+"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }

    /// Delete an item on the server (R2 objects + D1 row), then drop it
    /// from the Library list and the search results. Throws so the
    /// detail view can show the failure.
    func delete(item: Item) async throws {
        guard let api else { throw KeptoAPIError.notConfigured }
        try await api.delete(id: item.id)
        items.removeAll { $0.id == item.id }
        searchResults.removeAll { $0.id == item.id }
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
            if let index = searchResults.firstIndex(where: { $0.id == item.id }) {
                searchResults[index] = updated
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
