import AVFoundation
import CryptoKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Owns the library state. Cloud-only: media lives in R2/D1 behind
/// the Worker API; no photo or video is ever stored on disk. Only the
/// light listAll metadata (ids, titles, dates, flags) is cached on
/// disk (round-22) so the library renders instantly on launch, then
/// refreshes in the background. The app is Photos-style now:
/// the Library tab is a flat grid of all saved items (Years / Months /
/// Days / All Photos view modes are a presentation choice in the view,
/// not a server filter), the Albums tab shows per-creator and
/// user-created collections, and the Search tab filters by text or
/// platform. Pull-to-refresh re-fetches from the server.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// All saved items (Library tab, newest first).
    @Published private(set) var items: [Item] = [] {
        didSet { rebuildDerivedCache() }
    }
    /// Search results (Search tab only), newest first.
    @Published private(set) var searchResults: [Item] = []
    /// Library counts for the Photos-style header ("N Photos,
    /// M Videos") and the Albums tab. Nil until fetched (the
    /// /api/stats endpoint may be unavailable on an older Worker).
    @Published private(set) var libraryStats: LibraryStats?
    /// Light metadata for EVERY saved item (GET /api/listAll,
    /// fetched once after config load). Groupings
    /// (Years/Months/Days), Memories, Featured and synchronous
    /// local search all read this cache — never the paged `items`
    /// list — so they stay complete even before the user has
    /// scrolled through every page.
    @Published private(set) var allMetadata: [ItemMetadata] = [] {
        didSet { rebuildDerivedCache() }
    }
    /// True once the full metadata is available — from the disk
    /// cache (round-22) or a successful fetch. Local search falls
    /// back to the server only while this is false.
    @Published private(set) var allMetadataLoaded = false {
        didSet { rebuildDerivedCache() }
    }
    /// True once the network fetch has succeeded this launch. The
    /// disk cache also sets `allMetadataLoaded`, but the background
    /// refresh must still run once per launch (saves/deletes made
    /// elsewhere) — so the skip flag is the NETWORK load, not the
    /// disk load.
    private var allMetadataNetworkLoaded = false

    // MARK: - Cached derived data (round-13 perf)
    //
    // The Library grids used to derive these from `allMetadata` /
    // `items` with COMPUTED properties — a full re-sort of the whole
    // cache on every view access (every grid-cell onAppear /
    // onDisappear, every body evaluation, every maybeLoadMore call).
    // During scrolling that saturated the main thread and delayed
    // every gesture. They are now computed ONCE here, when the source
    // changes (didSet on allMetadata / items / allMetadataLoaded),
    // and every reader below is O(1). Same order, same ids, same
    // load-more boundary as the computed versions — only the timing
    // of the computation changed.
    /// All ids, oldest first (Apple Photos): the full-metadata cache
    /// when loaded, else the loaded pages.
    @Published private(set) var cachedAllIDs: [String] = []
    /// Metadata lookup by id (full cache; empty while not loaded).
    @Published private(set) var cachedMetadataById: [String: ItemMetadata] = [:]
    /// Loaded full-Item lookup by id.
    @Published private(set) var cachedItemsById: [String: Item] = [:]
    /// Index of each id inside cachedAllIDs (O(1) position lookup —
    /// the old maybeLoadMore scanned the whole list per cell).
    @Published private(set) var cachedIndexById: [String: Int] = [:]
    /// Grouped ids, oldest group first, ids inside each group oldest
    /// first — the same groupings the Library view used to compute
    /// per body evaluation.
    @Published private(set) var cachedDayGroups: [(key: Date, ids: [String])] = []
    @Published private(set) var cachedMonthGroups: [(key: Date, ids: [String])] = []
    @Published private(set) var cachedYearGroups: [(key: Date, ids: [String])] = []
    /// Index of the oldest loaded full Item inside cachedAllIDs
    /// (count - items.count): the load-more boundary.
    @Published private(set) var cachedOldestLoadedIndex: Int = 0
    /// Collections for the Albums tab (one per creator username).
    @Published private(set) var collections: [CollectionInfo] = []
    /// User-created collections ("My collections").
    @Published private(set) var myCollections: [MyCollection] = []
    // Round-13: starts true so the first paint is the loading view —
    // before, it started false and the empty state flashed for ~1s
    // while fetch() was still starting. The setup view still wins
    // when unconfigured (the view checks isConfigured first), and
    // fetch()/fetchCollections() clear it in their defer.
    @Published private(set) var isLoading = true
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    /// A link handed over by the Share Extension (kepto://save?url=...).
    /// The app root saves it directly, then clears it.
    @Published var pendingShareURL: String?

    /// Photo Library: the PhotosPicker presentation + selection.
    /// The picker itself is attached at the app root (KeptoTabView),
    /// so any tab's "…" menu can open it by setting
    /// `showingPhotoPicker = true`. Multi-select: up to 10 items.
    @Published var showingPhotoPicker = false
    @Published var selectedPhotos: [PhotosPickerItem] = []
    /// Choose Files: the Files-app document picker presentation.
    /// The picker itself is attached at the app root (KeptoTabView),
    /// like the PhotosPicker, so any tab's "…" menu can open it by
    /// setting `showingDocumentPicker = true`. Multi-select, images
    /// + videos; picked files are copied to temp and uploaded through
    /// the same pipeline as PhotosPicker picks.
    @Published var showingDocumentPicker = false
    /// True while a Photos import is in flight (the root shows a
    /// spinner pill with the progress).
    @Published var isUploading = false
    /// Batch-import progress (shown in the spinner pill as "2/5").
    @Published var uploadDone = 0
    @Published var uploadTotal = 0
    /// How many items in the last batch were duplicates (already saved
    /// — skipped automatically, the batch keeps going).
    @Published var uploadDuplicateCount = 0
    /// How many items in the last batch failed to import.
    @Published var uploadFailedCount = 0
    /// One-line notice after an import (shown by the root).
    @Published var uploadNotice: String?

    /// Album picker after a Photos import: it opens the moment the
    /// user picks photos (v57) — the user chooses the album while
    /// the files upload in the background. The items wait in
    /// importPickerItems until the choice is made (or Cancel — the
    /// items stay in the Library, in no album). This REPLACES the
    /// old auto-"Imports" behavior (v50): nothing is auto-added to
    /// any album any more.
    @Published var showingImportAlbumPicker = false
    /// The just-uploaded items awaiting an album choice.
    @Published var importPickerItems: [Item] = []
    /// Ids of items this session just imported (Photos/Files upload),
    /// set the moment an upload returns — before the Library refresh.
    /// The Library follows the newest one to the bottom even when the
    /// user was scrolled up: an import is a deliberate action and the
    /// user expects to see the new photo (the background-arrival rule
    /// — follow only if already at the bottom — does not apply here).
    /// Cleared by the Library once it has scrolled to the new item.
    @Published var justImportedIDs: Set<String> = []

    /// Called by the Library after it scrolled to a just-imported item.
    func clearJustImportedIDs() { justImportedIDs.removeAll() }
    /// The album the user picked in the import picker (nil = not
    /// chosen yet). Set the moment the user taps an album — even
    /// while the upload is still running. When the upload finishes,
    /// the items are added to this album automatically; if the user
    /// picks after the upload finished, they are added at once.
    @Published var chosenImportAlbum: MyCollection?

    /// The configured API client, or nil until the user enters a Worker URL
    /// and API key in Settings. Rebuilt by `reloadConfig()`.
    @Published private(set) var api: KeptoAPI?

    private var nextCursor: String?
    private var searchCursor: String?
    private var searchQuery: String?
    private var searchPlatform: Platform?
    private var isFetching = false
    private var isFetchingAllMetadata = false
    /// True when the current search results came from the local
    /// metadata cache (no more pages — all matches are already there).
    private var searchIsLocal = false
    /// Full Items resolved from light metadata matches (search),
    /// keyed by id. Seeded from every loaded page so repeat
    /// searches do not re-fetch items the Library already holds.
    private var resolvedItemsById: [String: Item] = [:]

    var isConfigured: Bool { api != nil }

    var hasMore: Bool { nextCursor != nil }

    init() {
        reloadConfig()
        // Render from the disk cache before the first network call
        // (round-22): the grid is up on launch, no waiting.
        loadAllMetadataFromDisk()
        // Round-25: start the background refresh at once, in
        // parallel with the first page fetch — it used to wait for
        // fetch()'s list to return, so the cache (and the album
        // seeds that read it) landed a full round trip late.
        // Guarded: a second call from fetch() is a no-op.
        Task { await fetchAllMetadata() }
        // Round-26: prefetch thumbnails missing from the cache
        // (disk-warm case) — the pipeline skips cached ids.
        prefetchMissingThumbnails()
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

    // MARK: - Full library metadata (GET /api/listAll)

    /// Fetch the full library metadata (GET /api/listAll). The
    /// NETWORK fetch runs at most once per launch (guard flag)
    /// unless `force` is set — save/upload pass force: true because
    /// the library just changed. A disk cache from the previous
    /// launch (round-22) renders first, so this fetch is a
    /// background refresh, not a gate. Quiet on failure: the Library
    /// grid, groupings and search keep working from the paged list /
    /// server search (or the disk cache), and the next fetch()
    /// retries (allMetadataNetworkLoaded stays false).
    func fetchAllMetadata(force: Bool = false) async {
        guard let api else { return }
        guard force || !allMetadataNetworkLoaded else { return }
        guard !isFetchingAllMetadata else { return }
        isFetchingAllMetadata = true
        defer { isFetchingAllMetadata = false }
        do {
            allMetadata = try await api.listAll()
            allMetadataLoaded = true
            allMetadataNetworkLoaded = true
            saveAllMetadataToDisk()
            // Round-26: the refresh may have brought new items —
            // prefetch their thumbnails (delta load).
            prefetchMissingThumbnails()
        } catch {
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            // Quiet — see above.
        }
    }

    /// Round-26: prefetch thumbnails for items missing them (delta
    /// load). nil = whole library newest-first (cachedAllIDs is
    /// ascending, so reversed); given ids = those in order.
    /// Fire-and-forget — the pipeline skips cached/in-flight ids,
    /// so re-calling is a cheap scan. No cancellation: the pipeline
    /// call is idempotent.
    func prefetchMissingThumbnails(ids: [String]? = nil) {
        guard let api else { return }
        let list: [String]
        if let ids {
            list = Array(ids.prefix(400))
        } else {
            list = Array(cachedAllIDs.reversed().prefix(400))
        }
        guard !list.isEmpty else { return }
        // Parent fix at merge: pass the list's own count, not 120 —
        // the pipeline works in order (newest first) in chunks of 4,
        // so the visible ones still land first and the rest follow
        // in the SAME background pass instead of waiting for the
        // next trigger to pick them up.
        ThumbnailPipeline.shared.prefetch(ids: list, api: api, limit: list.count)
    }

    // MARK: - listAll disk cache (round-22)
    //
    // The metadata cache used to live only in memory: every cold
    // launch re-downloaded GET /api/listAll before the Library grid
    // and the album seeds had anything to render. This file persists
    // ONLY the light metadata (ids, titles, dates, flags — no R2
    // keys, no media bytes), so launch renders from disk instantly
    // and the network fetch becomes a background refresh (SWR).
    // Media stays cloud-only, as before: nothing about a photo or
    // video is ever written to disk.
    private static var allMetadataCacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("listAll-cache.json")
    }

    /// Round-26: versioned envelope for the metadata disk cache.
    /// v1 carries the same [ItemMetadata] payload round-22 wrote
    /// as a bare array — the loader still accepts that old shape.
    private struct MetadataCacheFile: Codable {
        var v: Int
        var items: [ItemMetadata]
    }

    /// Load the persisted metadata cache, if any. Called from init:
    /// the grid renders from disk before the first network call.
    /// Corrupt or outdated files are ignored (the network fetch
    /// replaces them) — a bad cache must never block the library.
    private func loadAllMetadataFromDisk() {
        guard let url = Self.allMetadataCacheURL,
              let data = try? Data(contentsOf: url) else { return }
        // Round-26: the v1 envelope first, then the bare array
        // round-22 wrote — the user's device may already have
        // that file, and it must keep loading.
        if let envelope = try? JSONDecoder().decode(MetadataCacheFile.self, from: data),
           !envelope.items.isEmpty {
            allMetadata = envelope.items
            allMetadataLoaded = true
            return
        }
        guard let cached = try? JSONDecoder().decode([ItemMetadata].self, from: data),
              !cached.isEmpty else { return }
        allMetadata = cached
        allMetadataLoaded = true
    }

    /// Persist the metadata cache after a successful network fetch.
    /// Best-effort and silent: a failed write only costs the next
    /// launch its instant render, never the library itself.
    private func saveAllMetadataToDisk() {
        // Round-26: versioned envelope (v1 = the same payload
        // round-22 wrote as a bare array), so a future schema
        // change can migrate instead of silently dropping the cache.
        let envelope = MetadataCacheFile(v: 1, items: allMetadata)
        guard let url = Self.allMetadataCacheURL,
              let data = try? JSONEncoder().encode(envelope) else { return }
        // Round-25: the thumbnail cache already creates its
        // directory before writing; this one did not — if the
        // Application Support dir ever goes missing, the atomic
        // write fails silently and the cache never persists, so
        // every launch shows the loading screen again.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Recompute the cached derived data (see above) from the current
    /// `allMetadata` / `items` / `allMetadataLoaded`. Called from
    /// their didSet — once per source change, never per view access.
    /// Runs on the main actor: one O(n log n) sort per change is
    /// imperceptible; the same sort per frame was the lag.
    private func rebuildDerivedCache() {
        if allMetadataLoaded {
            let sorted = allMetadata.sortedChronologically()
            cachedAllIDs = sorted.map(\.id)
            cachedMetadataById = Dictionary(allMetadata.map { ($0.id, $0) }) { _, last in last }
            cachedDayGroups = groupedMetadata(by: [.year, .month, .day]).map { (key: $0.key, ids: $0.items.map(\.id)) }
            cachedMonthGroups = groupedMetadata(by: [.year, .month]).map { (key: $0.key, ids: $0.items.map(\.id)) }
            cachedYearGroups = groupedMetadata(by: [.year]).map { (key: $0.key, ids: $0.items.map(\.id)) }
        } else {
            let sorted = items.sortedChronologically()
            cachedAllIDs = sorted.map(\.id)
            cachedMetadataById = [:]
            cachedDayGroups = groupedItems(items, by: [.year, .month, .day])
            cachedMonthGroups = groupedItems(items, by: [.year, .month])
            cachedYearGroups = groupedItems(items, by: [.year])
        }
        cachedItemsById = Dictionary(items.map { ($0.id, $0) }) { _, last in last }
        var indexById: [String: Int] = [:]
        indexById.reserveCapacity(cachedAllIDs.count)
        for (index, id) in cachedAllIDs.enumerated() { indexById[id] = index }
        cachedIndexById = indexById
        cachedOldestLoadedIndex = max(cachedAllIDs.count - items.count, 0)
    }

    /// Group loaded full Items the same way `groupedMetadata` groups
    /// metadata (fallback while the listAll cache has not landed).
    private func groupedItems(_ items: [Item], by components: Set<Calendar.Component>) -> [(key: Date, ids: [String])] {
        let calendar = Calendar.current
        var groups: [Date: [Item]] = [:]
        for item in items {
            let comps = calendar.dateComponents(components, from: item.creationDate)
            guard let key = calendar.date(from: comps) else { continue }
            groups[key, default: []].append(item)
        }
        return groups.map { (key: $0.key, ids: $0.value.sortedByCreationDate().map(\.id)) }.sorted { $0.key < $1.key }
    }

    /// The full metadata cache grouped by the given calendar
    /// components (from each row's date taken), oldest group first.
    /// Same shape as the Library view's groupItems(by:) — but over
    /// the FULL library, so the sections are complete even before
    /// the user has scrolled through every page. Items inside a
    /// group are oldest first too (Apple Photos order).
    func groupedMetadata(by components: Set<Calendar.Component>) -> [(key: Date, items: [ItemMetadata])] {
        let calendar = Calendar.current
        var groups: [Date: [ItemMetadata]] = [:]
        for meta in allMetadata {
            let comps = calendar.dateComponents(components, from: meta.creationDate)
            guard let key = calendar.date(from: comps) else { continue }
            groups[key, default: []].append(meta)
        }
        return groups.map { (key: $0.key, items: $0.value.sortedByCreationDate()) }.sorted { $0.key < $1.key }
    }

    /// Full-library groupings: days / months / years, oldest first.
    var metadataByDay: [(key: Date, items: [ItemMetadata])] { groupedMetadata(by: [.year, .month, .day]) }
    var metadataByMonth: [(key: Date, items: [ItemMetadata])] { groupedMetadata(by: [.year, .month]) }
    var metadataByYear: [(key: Date, items: [ItemMetadata])] { groupedMetadata(by: [.year]) }

    /// Memories (For You, Photos rule Q7): one per month with >= 8
    /// items, max 8, newest first. Title is the month only
    /// ("MMMM yyyy") — Kepto items have no location, so there is
    /// no place part. (metadataByMonth is oldest first now, so the
    /// newest 8 are the suffix, reversed back to newest first —
    /// the same 8 months in the same order as before.)
    var memories: [(key: Date, items: [ItemMetadata])] {
        Array(metadataByMonth.filter { $0.items.count >= 8 }.suffix(8).reversed())
    }

    /// Featured Photos (Photos rule): favorites first, up to 24;
    /// when there are no favorites, the 16 newest items. Newest
    /// first either way (the cache arrives saved_at DESC).
    var featuredMetadata: [ItemMetadata] {
        let favorites = allMetadata.filter { $0.isFavorite }
        if favorites.isEmpty { return Array(allMetadata.prefix(16)) }
        return Array(favorites.prefix(24))
    }

    /// Synchronous local search over the full metadata cache
    /// (Photos-style): matches the query against title, caption,
    /// author, author username, platform display name, and the
    /// My-collection names of each item. Case- and
    /// diacritic-insensitive substring match (same scope as the
    /// server search, plus platform + collection names). An empty
    /// query with a platform set lists that whole platform; an
    /// empty query with no platform matches nothing.
    func searchLocal(query: String?, platform: Platform?) -> [ItemMetadata] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needle = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if needle.isEmpty && platform == nil { return [] }
        return allMetadata.filter { meta in
            if let platform, meta.platform != platform { return false }
            guard !needle.isEmpty else { return true }
            let fields = [meta.title, meta.caption, meta.author, meta.authorUsername,
                          meta.platform.displayName, meta.collectionName].compactMap { $0 }
                + meta.myCollectionNames
            return fields.contains {
                $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(needle)
            }
        }
    }

    /// Update one metadata row from a fresh full Item (e.g. after
    /// ingest finished and filled in caption/author). Keeps the
    /// listAll cache current without a full re-fetch. The
    /// My-collection membership comes from the cached row (a full
    /// Item carries no membership info).
    private func upsertMetadata(for item: Item) {
        guard let index = allMetadata.firstIndex(where: { $0.id == item.id }) else { return }
        let old = allMetadata[index]
        allMetadata[index] = ItemMetadata(
            id: item.id, platform: item.platform, title: item.title, caption: item.caption,
            author: item.author, authorUsername: item.authorUsername, postedAt: item.postedAt,
            savedAt: item.savedAt, contentType: item.contentType, duration: item.duration,
            width: item.width, height: item.height, fileSize: item.fileSize,
            isFavorite: item.isFavorite,
            myCollectionIds: old.myCollectionIds, myCollectionNames: old.myCollectionNames
        )
    }

    /// Copy of `item` with the favorite flag replaced. `Item` is all
    /// `let` except `isFavorite` (a `var` — the synthesized memberwise
    /// init omits defaulted properties, so `isFavorite` cannot be
    /// passed to it; it is assigned on the fresh copy instead).
    private func withFavorite(_ item: Item, _ favorite: Bool) -> Item {
        var copy = Item(
            id: item.id, userId: item.userId, platform: item.platform,
            originalUrl: item.originalUrl, r2Key: item.r2Key,
            thumbKey: item.thumbKey, previewKey: item.previewKey,
            contentType: item.contentType, title: item.title,
            caption: item.caption, author: item.author,
            authorUsername: item.authorUsername,
            authorAvatarUrl: item.authorAvatarUrl,
            postedAt: item.postedAt, savedAt: item.savedAt,
            duration: item.duration, width: item.width,
            height: item.height, fileSize: item.fileSize,
            sha256: item.sha256, previewCols: item.previewCols,
            previewRows: item.previewRows,
            previewInterval: item.previewInterval,
            previewCount: item.previewCount,
            viewCount: item.viewCount,
            status: item.status,
            ingestError: item.ingestError, createdAt: item.createdAt
        )
        copy.isFavorite = favorite
        return copy
    }

    /// Overlay the favorite flags from the allMetadata cache onto
    /// `items` (matched by id). GET /api/list as served by the
    /// deployed Worker omits `is_favorite`, so album items decode
    /// isFavorite=false even when favorited; the /api/listAll cache
    /// is the source of truth (Library hearts render from it).
    /// No-op until the cache has loaded — callers should re-apply
    /// when allMetadataLoaded flips.
    func applyingMetadataFavoriteFlags(to items: [Item]) -> [Item] {
        guard allMetadataLoaded else { return items }
        var flags: [String: Bool] = [:]
        flags.reserveCapacity(allMetadata.count)
        for meta in allMetadata { flags[meta.id] = meta.isFavorite }
        return items.map { item in
            guard let flag = flags[item.id], flag != item.isFavorite else { return item }
            return withFavorite(item, flag)
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
            // Cancellation is not an error — never show "cancelled".
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
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
            if error is CancellationError { return nil }
            if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
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
            if error is CancellationError { return nil }
            if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// One page of a user-created collection's items (used by
    /// PhotoCollectionScreen). Throws so the detail view can show it.
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
        // Round-27: the item still exists in the Library — only its
        // membership in this collection ends. Drop the id (and the
        // parallel name) from the cached metadata entry, or the
        // album reappears from the disk cache until the next
        // network refresh. Rebuild the derived cache: an in-place
        // element mutation does not fire the array's didSet.
        if let idx = allMetadata.firstIndex(where: { $0.id == item.id }),
           let idIdx = allMetadata[idx].myCollectionIds.firstIndex(of: collectionId) {
            allMetadata[idx].myCollectionIds.remove(at: idIdx)
            if allMetadata[idx].myCollectionNames.indices.contains(idIdx) {
                allMetadata[idx].myCollectionNames.remove(at: idIdx)
            }
            rebuildDerivedCache()
            saveAllMetadataToDisk()
        }
    }

    /// Delete a user-created collection. When deleteItems is true, the
    /// videos that live only in this album are deleted too (R2 + D1);
    /// a video that is also in another album stays saved. Throws so
    /// the caller can show the failure. After deleting videos, the
    /// Library refreshes so they disappear at once.
    func deleteMyCollection(id: String, deleteItems: Bool = false) async throws {
        guard let api else { throw KeptoAPIError.notConfigured }
        try await api.deleteMyCollection(id: id, deleteItems: deleteItems)
        myCollections.removeAll { $0.id == id }
        if deleteItems {
            await fetch()
            await fetchCollections()
            // Round-27: the deleted items are gone server-side, but
            // allMetadata (and its disk cache) still lists them —
            // force a full refresh so no ghost survives the delete.
            await fetchAllMetadata(force: true)
        }
    }

    /// Delete a whole creator album (a per-creator collection). This
    /// permanently deletes every video by that creator (R2 + D1) —
    /// there is no "album only" variant, because keeping the videos
    /// would just make the creator album reappear. Throws so the
    /// caller can show the failure. Refreshes the Library and the
    /// creator list so the deleted videos disappear at once.
    func deleteCreatorCollection(username: String) async throws {
        guard let api else { throw KeptoAPIError.notConfigured }
        try await api.deleteCreatorCollection(username: username)
        // Remove by id (authorUsername ?? "__unknown__") so the
        // "unknown" creator (NULL username) is removed too.
        collections.removeAll { $0.id == username }
        await fetch()
        await fetchCollections()
    }

    /// Rename a user collection. Updates the local list so the Albums
    /// tab shows the new name at once. Returns the updated collection,
    /// or nil (and errorMessage) on failure.
    func renameMyCollection(_ collection: MyCollection, name: String) async -> MyCollection? {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return nil
        }
        do {
            let updated = try await api.renameMyCollection(id: collection.id, name: name)
            if let index = myCollections.firstIndex(where: { $0.id == updated.id }) {
                myCollections[index] = updated
            }
            return updated
        } catch {
            if error is CancellationError { return nil }
            if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
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
    /// The background task polling for pending items to become ready.
    /// While it runs, a thumbnail appears as soon as its ingest
    /// finishes — no tab switch or pull-to-refresh needed.
    private var pendingPollTask: Task<Void, Never>?

    /// Start (or restart) the pending-items poll: while any item is
    /// still pending (ingesting), refetch every 5s so its thumbnail
    /// appears as soon as the ingest finishes — without the user
    /// having to switch tabs or pull to refresh. Stops on its own
    /// when nothing is pending (or after 5 minutes, so a stuck item
    /// does not poll forever). Called after every save/upload and
    /// when the Library appears, so a new pending item always starts
    /// a poll. Safe to call when nothing is pending (it exits at once).
    /// The poll lives in the ViewModel (not in the View's .task), so
    /// it keeps running even if the user switches tabs — when they
    /// switch back, the thumbnail is already there.
    func startPendingPoll() {
        pendingPollTask?.cancel()
        pendingPollTask = Task { [weak self] in
            guard let self else { return }
            var polls = 0
            while !Task.isCancelled
                    && self.items.contains(where: { $0.status == .pending })
                    && polls < 60 {
                polls += 1
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await self.fetch()
            }
        }
    }

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
            for item in page { resolvedItemsById[item.id] = item }
            // Kick off the one-time full-metadata fetch (listAll) in
            // the background — groupings, Memories and local search
            // read it. fetch() itself returns as soon as the first
            // page is in.
            Task { await fetchAllMetadata() }
            // Round-26: prefetch thumbnails for items newly ready
            // (the pending poll lands them here).
            prefetchMissingThumbnails()
        } catch {
            // Cancellation is not an error — the task was superseded
            // (view gone, refresh re-triggered). Never show it as an
            // alert ("cancelled"); just stop quietly.
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
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
            for item in page { resolvedItemsById[item.id] = item }
        } catch {
            // Cancellation is not an error (scroll task superseded) —
            // never show it as an alert ("cancelled").
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Materialize light metadata matches to full Items. Prefers the
    /// in-memory paged `items` + the resolved cache; fetches the
    /// rest by id, concurrently. Order follows the matches
    /// (newest first). Used by `resolveItems` (Search/For You feeds).
    private func resolveSearchItems(_ matches: [ItemMetadata]) async -> [Item] {
        guard let api else { return [] }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [Item?] = Array(repeating: nil, count: matches.count)
        var missing: [(index: Int, id: String)] = []
        for (index, meta) in matches.enumerated() {
            if let item = byId[meta.id] ?? resolvedItemsById[meta.id] {
                found[index] = item
            } else {
                missing.append((index, meta.id))
            }
        }
        if !missing.isEmpty {
            let fetched = await withTaskGroup(of: (Int, Item?).self) { group in
                for (index, id) in missing {
                    group.addTask { (index, try? await api.getItem(id: id)) }
                }
                var out: [(Int, Item?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (index, item) in fetched {
                if let item {
                    found[index] = item
                    resolvedItemsById[item.id] = item
                }
            }
        }
        return found.compactMap { $0 }
    }

    /// Materialize light metadata matches to full Items (for the
    /// ported SearchView's feed: tap a result, page through the
    /// matches). Same resolver the Search/For You feeds use.
    func resolveItems(_ matches: [ItemMetadata]) async -> [Item] {
        await resolveSearchItems(matches)
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

    /// One page of videos or photos only (used by the Albums tab's
    /// Media Types rows). `media` is "video" or "image" — the API's
    /// spelling. Throws so the detail view can show it.
    /// (Step 4: added for the media-filtered browser; this copy
    /// supersedes the step-3 staged LibraryViewModel.swift.)
    func listMedia(_ media: String,
                   limit: Int = 50,
                   cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        guard let api else { throw KeptoAPIError.notConfigured }
        return try await api.list(media: media, limit: limit, cursor: cursor)
    }

    /// One page of a collection's items (used by PhotoCollectionScreen).
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
            // The library just changed — refresh the full metadata
            // cache too, so groupings and local search include the
            // new item(s) at once.
            await fetchAllMetadata(force: true)
            // The new item(s) are pending (ingesting) — start the poll
            // so their thumbnails appear when the ingest finishes.
            startPendingPoll()
            return result
        } catch {
            if error is CancellationError { return nil }
            if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Upload a photo/video from the device Albums. The file is sent to
    /// the Worker, which forwards it to the ingest service. Returns the
    /// finished item and whether it was a duplicate (nil + false on
    /// failure, errorMessage set). `sha256` is the SHA-256 of the exact
    /// bytes being uploaded; when it matches an item already saved, the
    /// Worker returns that item as a duplicate instead of uploading
    /// again (and no Library refresh is needed — it is already there).
    /// After a fresh upload the Library and the Albums tab both refresh,
    /// so the new item shows up.
    func upload(fileURL: URL, filename: String, mimeType: String, sha256: String? = nil) async -> (item: Item?, duplicate: Bool) {
        guard let api else {
            errorMessage = KeptoAPIError.notConfigured.errorDescription
            return (nil, false)
        }
        do {
            let (item, duplicate) = try await api.uploadFile(fileURL: fileURL, filename: filename, mimeType: mimeType, sha256: sha256)
            if !duplicate {
                // Mark it before the refresh below, so the Library's
                // onChange sees it as a fresh import (not a background
                // arrival) and scrolls to it even from mid-list.
                // (item is non-optional here — uploadFile returns Item,
                // not Item? — so no `if let`.)
                justImportedIDs.insert(item.id)
                // Round-26: insert into the caches NOW instead of
                // re-downloading all metadata — the next launch and
                // the next album open already have this item. The
                // didSet on allMetadata/items rebuilds the derived
                // cache; fetch() below refreshes the page in place.
                if !allMetadata.contains(where: { $0.id == item.id }) {
                    allMetadata.append(ItemMetadata(from: item))
                    saveAllMetadataToDisk()
                }
                if !items.contains(where: { $0.id == item.id }) {
                    items.insert(item, at: 0)
                }
                resolvedItemsById[item.id] = item
                await fetch()
                await fetchCollections()
                // The new item is pending (ingesting) — start the poll
                // so its thumbnail appears when the ingest finishes.
                startPendingPoll()
            }
            return (item, duplicate)
        } catch {
            if error is CancellationError { return (nil, false) }
            if let urlError = error as? URLError, urlError.code == .cancelled { return (nil, false) }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (nil, false)
        }
    }

    /// Upload the photos/videos the user just picked in the PhotosPicker
    /// (up to 10 at once), one by one so a slow connection does not
    /// pile up parallel uploads. The root shows a spinner pill with
    /// the progress ("Đang tải lên 2/5…"). A duplicate (already saved —
    /// same content hash) is skipped automatically and the batch keeps
    /// going; the summary notice says how many were skipped. After
    /// uploading, the user CHOOSES an album for the new items (the
    /// album picker sheet) — nothing is auto-added to "Imports" any
    /// more (that was the v50 behavior, removed in v56).
    /// Open the photo picker to add photos straight into `collection`
    /// (from an album's long-press menu in Albums). The album is
    /// pre-chosen, so the Add to Album picker is skipped — the items
    /// go into this album when the upload finishes. If the user
    /// cancels the picker without choosing, KeptoApp clears the
    /// pre-choice so a later import doesn't land in the wrong album.
    func addPhotos(to collection: MyCollection) {
        chosenImportAlbum = collection
        showingPhotoPicker = true
    }

    func uploadPickedPhotos(_ items: [PhotosPickerItem]) async {
        isUploading = true
        uploadTotal = items.count
        uploadDone = 0
        // Show the Add to Album picker RIGHT AWAY (v57): the user
        // picks the album while the files upload in the background,
        // instead of waiting for the whole batch to finish. The
        // choice is stored in chosenImportAlbum; the items are added
        // to it when the upload finishes (or at once, if the user
        // picks after the upload finished).
        importPickerItems = []
        // If an album was pre-chosen (Add Photos from an album's
        // long-press menu), keep it and skip the picker — the items
        // go straight into that album when the upload finishes.
        // Otherwise show the picker so the user chooses.
        let preChosenAlbum = chosenImportAlbum
        await fetchMyCollections()
        if preChosenAlbum == nil {
            showingImportAlbumPicker = true
        }
        defer {
            isUploading = false
            uploadTotal = 0
            uploadDone = 0
        }
        var uploaded: [Item] = []
        var duplicates = 0
        var failed = 0
        for item in items {
            switch await uploadOnePickedPhoto(item) {
            case .uploaded(let created):
                uploaded.append(created)
                importPickerItems.append(created)
            case .duplicate:
                duplicates += 1
            case .failed:
                failed += 1
            }
            uploadDone += 1
        }
        uploadDuplicateCount = duplicates
        uploadFailedCount = failed
        if uploaded.isEmpty {
            // Nothing to add — close the picker (the user may have
            // already picked an album, but there are no items for it).
            showingImportAlbumPicker = false
            importPickerItems = []
            chosenImportAlbum = nil
            if duplicates > 0 && failed == 0 {
                uploadNotice = "Tất cả đã có trước đó (\(duplicates) trùng, đã bỏ qua)."
            } else if duplicates > 0 {
                uploadNotice = "Không tải lên được mục mới (\(duplicates) trùng, \(failed) lỗi)."
            } else {
                uploadNotice = "Không tải lên được. Thử lại nhé."
            }
            return
        }
        // Upload done. Turn isUploading off BEFORE the add check:
        // addImportItemsToAlbum (called from the picker) decides by
        // this flag whether to add now or defer to here, and the user
        // may tap an album in the same moment this finishes.
        isUploading = false
        if chosenImportAlbum != nil {
            await addItemsToChosenAlbum()
        } else if !showingImportAlbumPicker {
            // The user cancelled while uploading — the items stay in
            // the Library, in no album. Clear the staging list.
            importPickerItems = []
        }
        // Otherwise the picker is still open: the user picks an
        // album and addImportItemsToAlbum adds these items at once.
    }

    /// Upload the files the user just picked in the Files app
    /// (Choose Files), one by one — the same flow as
    /// `uploadPickedPhotos`: spinner pill with progress, duplicates
    /// skipped, album picker right away (unless an album was
    /// pre-chosen), same notices. The per-file step is
    /// `uploadOnePickedFile`; the batch scaffolding is a mirror of
    /// `uploadPickedPhotos` on purpose (same calls, same order) so
    /// the two paths cannot drift apart in behavior.
    func uploadPickedFiles(_ urls: [URL]) async {
        isUploading = true
        uploadTotal = urls.count
        uploadDone = 0
        // Show the Add to Album picker RIGHT AWAY (v57): the user
        // picks the album while the files upload in the background,
        // instead of waiting for the whole batch to finish. The
        // choice is stored in chosenImportAlbum; the items are added
        // to it when the upload finishes (or at once, if the user
        // picks after the upload finished).
        importPickerItems = []
        // If an album was pre-chosen (Add Photos from an album's
        // long-press menu), keep it and skip the picker — the items
        // go straight into that album when the upload finishes.
        // Otherwise show the picker so the user chooses.
        let preChosenAlbum = chosenImportAlbum
        await fetchMyCollections()
        if preChosenAlbum == nil {
            showingImportAlbumPicker = true
        }
        defer {
            isUploading = false
            uploadTotal = 0
            uploadDone = 0
        }
        var uploaded: [Item] = []
        var duplicates = 0
        var failed = 0
        for url in urls {
            switch await uploadOnePickedFile(url) {
            case .uploaded(let created):
                uploaded.append(created)
                importPickerItems.append(created)
            case .duplicate:
                duplicates += 1
            case .failed:
                failed += 1
            }
            uploadDone += 1
        }
        uploadDuplicateCount = duplicates
        uploadFailedCount = failed
        if uploaded.isEmpty {
            // Nothing to add — close the picker (the user may have
            // already picked an album, but there are no items for it).
            showingImportAlbumPicker = false
            importPickerItems = []
            chosenImportAlbum = nil
            if duplicates > 0 && failed == 0 {
                uploadNotice = "Tất cả đã có trước đó (\(duplicates) trùng, đã bỏ qua)."
            } else if duplicates > 0 {
                uploadNotice = "Không tải lên được mục mới (\(duplicates) trùng, \(failed) lỗi)."
            } else {
                uploadNotice = "Không tải lên được. Thử lại nhé."
            }
            return
        }
        // Upload done. Turn isUploading off BEFORE the add check:
        // addImportItemsToAlbum (called from the picker) decides by
        // this flag whether to add now or defer to here, and the user
        // may tap an album in the same moment this finishes.
        isUploading = false
        if chosenImportAlbum != nil {
            await addItemsToChosenAlbum()
        } else if !showingImportAlbumPicker {
            // The user cancelled while uploading — the items stay in
            // the Library, in no album. Clear the staging list.
            importPickerItems = []
        }
        // Otherwise the picker is still open: the user picks an
        // album and addImportItemsToAlbum adds these items at once.
    }

    /// Upload one file picked in the Files app (Choose Files).
    /// Videos are uploaded as-is; photos are converted to JPEG first
    /// (same HEIC rule as the PhotosPicker path). The file URL comes
    /// from the document picker with `asCopy: true`, so it is already
    /// a copy in the app's temp directory — readable directly, and
    /// removed after the upload like the PhotosPicker temp files.
    /// The SHA-256 of the exact bytes being uploaded is sent along,
    /// so the Worker can skip a file that is already saved (same
    /// content hash) instead of uploading it again.
    private func uploadOnePickedFile(_ url: URL) async -> UploadOneResult {
        let ext = url.pathExtension
        let type = UTType(filenameExtension: ext)
        let isVideo = type?.conforms(to: .video) == true || type?.conforms(to: .movie) == true
        if isVideo {
            defer { try? FileManager.default.removeItem(at: url) }
            let filename = url.lastPathComponent
            let mimeType = mimeType(for: ext)
            let hash = sha256Hex(ofFile: url)
            let (uploaded, duplicate) = await upload(fileURL: url, filename: filename, mimeType: mimeType, sha256: hash)
            if let uploaded {
                return duplicate ? .duplicate : .uploaded(uploaded)
            }
            return .failed
        }
        // Photo: read the bytes, decode, re-encode as JPEG (HEIC ->
        // JPEG — the ingest cannot convert HEIC), same as the
        // PhotosPicker path.
        defer { try? FileManager.default.removeItem(at: url) }
        guard let rawData = try? Data(contentsOf: url),
              let image = UIImage(data: rawData),
              let data = image.jpegData(compressionQuality: 0.9) else {
            errorMessage = "Không đọc được ảnh đã chọn."
            return .failed
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kepto-upload-\(UUID().uuidString).jpg")
        do {
            try data.write(to: tempURL)
        } catch {
            errorMessage = "Không chuẩn bị được ảnh để tải lên."
            return .failed
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let filename = url.deletingPathExtension().lastPathComponent + ".jpg"
        let hash = sha256Hex(of: data)
        let (uploaded, duplicate) = await upload(fileURL: tempURL, filename: filename, mimeType: "image/jpeg", sha256: hash)
        if let uploaded {
            return duplicate ? .duplicate : .uploaded(uploaded)
        }
        return .failed
    }

    /// The user picked an album for the just-imported items. Record
    /// the choice and close the picker. If the upload already
    /// finished, add the items to the album at once; if it is still
    /// running, uploadPickedPhotos adds them when it completes.
    func addImportItemsToAlbum(_ collection: MyCollection) async {
        chosenImportAlbum = collection
        showingImportAlbumPicker = false
        guard !isUploading, !importPickerItems.isEmpty else { return }
        await addItemsToChosenAlbum()
    }

    /// Add the staged items (importPickerItems) to the album the user
    /// chose (chosenImportAlbum), then report the result. The notice
    /// also says how many were skipped as duplicates/failed. Called
    /// when the upload finishes (if the user already picked) or when
    /// the user picks an album after the upload finished.
    private func addItemsToChosenAlbum() async {
        guard let collection = chosenImportAlbum else { return }
        let items = importPickerItems
        importPickerItems = []
        chosenImportAlbum = nil
        showingImportAlbumPicker = false
        var added = 0
        for item in items {
            if await addItemToMyCollection(collectionId: collection.id, item: item) == true {
                added += 1
            }
        }
        var notice = "Đã thêm \(added) ảnh/video vào album “\(collection.name)”."
        var skipped: [String] = []
        if uploadDuplicateCount > 0 { skipped.append("\(uploadDuplicateCount) trùng, đã bỏ qua") }
        if uploadFailedCount > 0 { skipped.append("\(uploadFailedCount) lỗi") }
        if !skipped.isEmpty {
            notice += " (\(skipped.joined(separator: "; ")).)"
        }
        uploadNotice = notice
    }

    /// Create a new album from the import picker and add the
    /// just-imported items to it. Returns nil (and errorMessage) on
    /// failure; the picker stays open so the user can pick another.
    func createImportAlbum(name: String) async -> MyCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let collection = await createMyCollection(name: trimmed) else { return nil }
        await addImportItemsToAlbum(collection)
        return collection
    }

    /// Result of uploading one picked photo/video.
    private enum UploadOneResult {
        /// A fresh upload (the returned item).
        case uploaded(Item)
        /// Already saved — same content hash, skipped, no new item.
        case duplicate
        /// Could not be read or uploaded (errorMessage is set).
        case failed
    }

    /// Upload one picked photo/video. Photos are converted to JPEG first
    /// (iPhone photos are HEIC and the ingest cannot convert HEIC);
    /// videos are uploaded as-is. The SHA-256 of the exact bytes being
    /// uploaded is sent along, so the Worker can skip a file that is
    /// already saved (same content hash) instead of uploading it again.
    private func uploadOnePickedPhoto(_ item: PhotosPickerItem) async -> UploadOneResult {
        // Video: picker-native transfer only (round-24). The old
        // path fetched the PHAsset by itemIdentifier, but the app
        // declares ONLY NSPhotoLibraryAddUsageDescription and
        // requests only .addOnly authorization — PHAsset.fetchAssets
        // returns empty without read access, so EVERY video failed
        // here with "Không đọc được video đã chọn." (photos worked
        // because they already used loadTransferable, which needs no
        // PhotoKit permission). Two attempts, cheapest first:
        // (1) loadTransferable(URL) — the system hands a file
        // (copying/transcoding as needed), nothing held in memory;
        // (2) loadTransferable(Data) — the picker downloads the
        // video (incl. iCloud) and hands the bytes; written to a
        // temp file for the upload. The Worker's ~100 MB limit
        // bounds the Data attempt.
        let types = item.supportedContentTypes
        let isVideo = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        if isVideo {
            if let pickedURL = try? await item.loadTransferable(type: URL.self) {
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kepto-video-\(UUID().uuidString).\(pickedURL.pathExtension)")
                if (try? FileManager.default.copyItem(at: pickedURL, to: dest)) != nil {
                    defer { try? FileManager.default.removeItem(at: dest) }
                    let mimeType = mimeType(for: dest.pathExtension)
                    let hash = sha256Hex(ofFile: dest)
                    // Round-26: start the first-frame capture now,
                    // while the file still exists — the upload takes
                    // seconds and the defer above deletes the file
                    // at return.
                    let thumbTask = Task.detached { Self.videoThumbnail(from: dest) }
                    let (uploaded, duplicate) = await upload(fileURL: dest, filename: pickedURL.lastPathComponent, mimeType: mimeType, sha256: hash)
                    if let uploaded {
                        if !duplicate, let thumb = await thumbTask.value {
                            KeptoAPI.storeThumbnail(id: uploaded.id, image: thumb)
                        }
                        return duplicate ? .duplicate : .uploaded(uploaded)
                    }
                    return .failed
                }
            }
            let ext = types.first { $0.conforms(to: .movie) || $0.conforms(to: .video) }?.preferredFilenameExtension ?? "mp4"
            guard let videoData = try? await item.loadTransferable(type: Data.self), !videoData.isEmpty else {
                errorMessage = "Không đọc được video đã chọn."
                return .failed
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kepto-video-\(UUID().uuidString).\(ext)")
            do {
                try videoData.write(to: tempURL)
            } catch {
                errorMessage = "Không chuẩn bị được video để tải lên."
                return .failed
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let hash = sha256Hex(of: videoData)
            // Round-26: first-frame capture starts before the upload
            // (same reason as the URL path above — the file is gone
            // at return).
            let thumbTask = Task.detached { Self.videoThumbnail(from: tempURL) }
            let (uploaded, duplicate) = await upload(fileURL: tempURL, filename: "video.\(ext)", mimeType: mimeType(for: ext), sha256: hash)
            if let uploaded {
                if !duplicate, let thumb = await thumbTask.value {
                    KeptoAPI.storeThumbnail(id: uploaded.id, image: thumb)
                }
                return duplicate ? .duplicate : .uploaded(uploaded)
            }
            return .failed
        }
        // Photo: load the raw bytes (Data conforms to Transferable;
        // UIImage does not), decode them, and re-encode as JPEG
        // (HEIC -> JPEG — the ingest cannot convert HEIC).
        guard let rawData = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: rawData),
              let data = image.jpegData(compressionQuality: 0.9) else {
            errorMessage = "Không đọc được ảnh đã chọn."
            return .failed
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kepto-upload-\(UUID().uuidString).jpg")
        do {
            try data.write(to: tempURL)
        } catch {
            errorMessage = "Không chuẩn bị được ảnh để tải lên."
            return .failed
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let hash = sha256Hex(of: data)
        let (uploaded, duplicate) = await upload(fileURL: tempURL, filename: "photo.jpg", mimeType: "image/jpeg", sha256: hash)
        if let uploaded {
            if !duplicate {
                // Round-26: cache the thumbnail now from the JPEG
                // already in memory — off-main, fire-and-forget,
                // never blocks the return.
                Task.detached {
                    if let img = UIImage(data: data) {
                        KeptoAPI.storeThumbnail(id: uploaded.id, image: img)
                    }
                }
            }
            return duplicate ? .duplicate : .uploaded(uploaded)
        }
        return .failed
    }

    /// Round-26: first frame of a video file as a UIImage (for the
    /// save-time thumbnail cache). Synchronous — callers run it off
    /// the main actor. Nil when the frame cannot be read.
    private static func videoThumbnail(from fileURL: URL) -> UIImage? {
        let asset = AVAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// SHA-256 of data, as a lowercase hex string (for content-hash dedupe).
    private func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file on disk, read in 1 MB chunks — a video can be
    /// tens of MB, so the whole file is never loaded into memory to
    /// hash it. Returns nil when the file cannot be read (the upload
    /// then proceeds without a hash, so no dedupe for that file).
    private func sha256Hex(ofFile fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// MIME type for a video file extension (used for the upload body).
    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "mp4": return "video/mp4"
        default: return "video/mp4"
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
        allMetadata.removeAll { $0.id == item.id }
        resolvedItemsById.removeValue(forKey: item.id)
        // Round-27: persist the removal — without this the disk
        // cache still holds the deleted item and the next launch
        // renders a ghost until the network refresh replaces it.
        // Its thumbnail goes too, from both cache layers.
        saveAllMetadataToDisk()
        KeptoAPI.removeCachedThumbnail(id: item.id)
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
            // The value being set. The server confirms the write,
            // but its returned item omits is_favorite (deployed
            // Worker lags), so it always decodes false — trust the
            // request, or the toast, the heart and the cache all
            // go wrong.
            let requested = !item.isFavorite
            let updated = try await api.setFavorite(id: item.id, favorite: requested)
            let fixed = withFavorite(updated, requested)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = fixed
            }
            if let index = searchResults.firstIndex(where: { $0.id == item.id }) {
                searchResults[index] = fixed
            }
            resolvedItemsById[fixed.id] = fixed
            // Keep the full-metadata cache in sync too — the Library
            // grid reads its favorite hearts from there (step 3), so
            // without this the heart would not flip until the next
            // listAll refetch.
            upsertMetadata(for: fixed)
            return fixed
        } catch {
            if error is CancellationError { return nil }
            if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Refresh one item in place (used after returning from the detail view,
    /// e.g. a pending item may have become ready).
    func refreshItem(_ item: Item) async {
        guard let api else { return }
        guard let updated = try? await api.getItem(id: item.id) else { return }
        // The fetched item may omit is_favorite (deployed Worker);
        // keep the cached flag when the cache knows it, or a
        // refresh would un-heart the item and poison the cache.
        let merged = applyingMetadataFavoriteFlags(to: [updated]).first ?? updated
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = merged
        }
        resolvedItemsById[merged.id] = merged
        upsertMetadata(for: merged)
    }

    /// Fetch one item fresh from the server (used by the detail view so
    /// it never shows stale fields — e.g. a preview that only exists
    /// after ingest finished). Returns nil on failure.
    func fetchItem(id: String) async -> Item? {
        guard let api else { return nil }
        guard let item = try? await api.getItem(id: id) else { return nil }
        // Same is_favorite caveat as refreshItem: overlay the cached
        // flag so a single-item fetch never un-hearts it.
        return applyingMetadataFavoriteFlags(to: [item]).first ?? item
    }
}
