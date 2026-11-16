import CryptoKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    /// Import from Photos: the PhotosPicker presentation + selection.
    /// The picker itself is attached at the app root (KeptoTabView),
    /// so any tab's "…" menu can open it by setting
    /// `showingPhotoPicker = true`. Multi-select: up to 10 items.
    @Published var showingPhotoPicker = false
    @Published var selectedPhotos: [PhotosPickerItem] = []
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

    /// Album picker after a Photos import: the just-uploaded items
    /// wait here until the user chooses an album for them (or taps
    /// Cancel — the items stay in the Library, in no album). This
    /// REPLACES the old auto-"Imports" behavior (v50): nothing is
    /// auto-added to any album any more.
    @Published var showingImportAlbumPicker = false
    /// The just-uploaded items awaiting an album choice.
    @Published var importPickerItems: [Item] = []

    /// Albums tab re-tap (Photos behavior): incremented by the app
    /// root (KeptoTabView) when the user taps the Albums tab while
    /// it is already selected. The Albums stack observes this:
    /// if the visible list is scrolled down it scrolls to the top;
    /// if it is already at the top it pops back to the Albums root.
    @Published var albumsTabTapCount = 0
    /// Whether the currently-visible view in the Albums navigation
    /// stack is scrolled to the top. Updated by each Albums-stack
    /// ScrollView (via onScrollGeometryChange); only the topmost
    /// view is visible, so this reflects the visible one.
    @Published var albumsStackAtTop = true
    /// Set by an album detail view when a re-tap should pop to the
    /// Albums root (the detail is already at the top). AlbumsView
    /// observes this, clears its navigation, and resets it.
    @Published var albumsPopToRootRequested = false

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
        } catch {
            // Cancellation is not an error (scroll task superseded) —
            // never show it as an alert ("cancelled").
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
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
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
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
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
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
    func uploadPickedPhotos(_ items: [PhotosPickerItem]) async {
        isUploading = true
        uploadTotal = items.count
        uploadDone = 0
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
            if duplicates > 0 && failed == 0 {
                uploadNotice = "Tất cả đã có trước đó (\(duplicates) trùng, đã bỏ qua)."
            } else if duplicates > 0 {
                uploadNotice = "Không tải lên được mục mới (\(duplicates) trùng, \(failed) lỗi)."
            } else {
                uploadNotice = "Không tải lên được. Thử lại nhé."
            }
            return
        }
        // Do NOT auto-add to "Imports" any more (v56). Show the album
        // picker so the user chooses where these items go.
        importPickerItems = uploaded
        await fetchMyCollections()
        showingImportAlbumPicker = true
    }

    /// Add the just-imported items (importPickerItems) to the chosen
    /// album, then close the picker and report the result. The
    /// notice also says how many were skipped as duplicates/failed.
    func addImportItemsToAlbum(_ collection: MyCollection) async {
        let items = importPickerItems
        importPickerItems = []
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
        // Video: the picker hands back a file URL (a temp copy).
        let types = item.supportedContentTypes
        let isVideo = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        if isVideo {
            guard let fileURL = try? await item.loadTransferable(type: URL.self) else {
                errorMessage = "Không đọc được video đã chọn."
                return .failed
            }
            let filename = fileURL.lastPathComponent
            let mimeType = mimeType(for: fileURL.pathExtension)
            let hash = sha256Hex(ofFile: fileURL)
            let (uploaded, duplicate) = await upload(fileURL: fileURL, filename: filename, mimeType: mimeType, sha256: hash)
            if let uploaded {
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
            return duplicate ? .duplicate : .uploaded(uploaded)
        }
        return .failed
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
