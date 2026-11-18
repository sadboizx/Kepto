import Foundation
import UIKit

/// Errors surfaced to the user as plain messages (no technical jargon in UI).
enum KeptoAPIError: Error, LocalizedError {
    case notConfigured
    case unauthorized
    case notFound
    case invalidURL
    case server(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Chưa cấu hình Worker. Mở Settings và nhập Worker URL + API key."
        case .unauthorized:
            return "API key không đúng. Kiểm tra lại trong Settings."
        case .notFound:
            return "Không tìm thấy item này (có thể đã bị xóa)."
        case .invalidURL:
            return "Link không hợp lệ. Dán link bắt đầu bằng https://."
        case .server(let message):
            return message
        case .network:
            return "Không có mạng hoặc Worker không trả lời. Kiểm tra kết nối rồi thử lại."
        }
    }
}

/// Thin HTTP client for the Kepto Workers backend.
/// No URL, API key, or secret is hardcoded here: the base URL comes from
/// UserDefaults (set in Settings) and the API key from the Keychain.
/// Cloud-only: this client never downloads media to Photos or to disk —
/// playback streams from the Worker and thumbnails are cached in
/// memory (NSCache) + on disk (Caches/thumbnails, previews only).
final class KeptoAPI {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    /// Shared in-memory thumbnail cache (Photos-style smooth scrolling).
    /// Thumbnails are remote (R2 via the Worker), not PHAssets, so
    /// PHCachingImageManager does not apply — this NSCache is the
    /// equivalent: a grid cell that scrolls off-screen and back does
    /// NOT re-download its thumbnail, and thousands of items stay
    /// smooth because only decoded UIImages are kept (NSCache evicts
    /// under memory pressure). Keyed by the size-qualified key
    /// `thumbnail_<id>_400` (round-26), with a cost of pixel bytes
    /// per image. Bounded: 300 images / 100 MB — the disk layer
    /// underneath (round-23) re-serves anything evicted.
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    /// Size-qualified cache key (round-26): one entry per item id at
    /// the grid size (400px max side). The same key names the NSCache
    /// entry and the disk file, so the two layers can never disagree
    /// about what is cached.
    private static func thumbnailCacheKey(for id: String) -> NSString {
        "thumbnail_\(id)_400" as NSString
    }

    /// Pixel bytes of a decoded image (width * height * scale^2 * 4),
    /// used as the NSCache cost so totalCostLimit tracks real RAM.
    private static func thumbnailCost(_ image: UIImage) -> Int {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        return Int(pixelWidth * pixelHeight * 4)
    }

    /// Disk thumbnail cache (round-23): one JPEG per item id under
    /// Caches/thumbnails, named `thumbnail_<id>_400.jpg` (round-26;
    /// round-23 files were plain "<id>.jpg" and are migrated on
    /// read). Layered under the NSCache above — a
    /// thumbnail survives app restarts, so the grid renders with
    /// real images on launch instead of gray placeholders waiting
    /// on the network. Caches (not Application Support): the bytes
    /// are regenerable from the Worker, and the system may purge
    /// them under storage pressure — a purge only costs a
    /// re-download, never data. Thumbnails are immutable per item
    /// id (generated at ingest; a re-save gets a new id), so no
    /// invalidation is needed. Total size is capped; the oldest
    /// files go first when the cap is exceeded.
    private static let thumbnailDiskCapBytes = 300 * 1024 * 1024

    private static var thumbnailDiskDirectory: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let thumbs = dir.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        return thumbs
    }

    private static func thumbnailDiskURL(for id: String) -> URL? {
        thumbnailDiskDirectory?.appendingPathComponent("thumbnail_\(id)_400.jpg")
    }

    /// Legacy disk filename (round-23): plain "<id>.jpg". Only used
    /// to read + migrate old files — new writes always use the
    /// size-qualified name above.
    private static func thumbnailLegacyDiskURL(for id: String) -> URL? {
        thumbnailDiskDirectory?.appendingPathComponent("\(id).jpg")
    }

    /// Read a thumbnail from disk, if present. Nil when missing or
    /// undecodable — the caller falls through to the network.
    /// A legacy "<id>.jpg" file (round-23) is read as a fallback
    /// and MIGRATED to the new name on hit, so old files are not
    /// re-downloaded and the legacy name disappears over time.
    private static func thumbnailFromDisk(id: String) -> UIImage? {
        guard let url = thumbnailDiskURL(for: id) else { return nil }
        if let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        guard let legacyURL = thumbnailLegacyDiskURL(for: id),
              let data = try? Data(contentsOf: legacyURL),
              let image = UIImage(data: data) else { return nil }
        try? FileManager.default.moveItem(at: legacyURL, to: url)
        return image
    }

    /// True when a thumbnail is already cached for this id — in
    /// memory or on disk (new name or legacy). Sync, no network:
    /// the prefetch layer uses it to fetch only what is missing.
    static func hasCachedThumbnail(id: String) -> Bool {
        if thumbnailCache.object(forKey: thumbnailCacheKey(for: id)) != nil {
            return true
        }
        let fm = FileManager.default
        if let url = thumbnailDiskURL(for: id), fm.fileExists(atPath: url.path) {
            return true
        }
        if let legacyURL = thumbnailLegacyDiskURL(for: id), fm.fileExists(atPath: legacyURL.path) {
            return true
        }
        return false
    }

    /// Save-time write API (round-26): store a freshly saved item's
    /// thumbnail at once so the next Library/Album open already has
    /// it — no waiting for the grid to request it. The image is
    /// downscaled to the 400px grid size and stored as JPEG 0.8 in
    /// both layers (NSCache with cost + disk). Best-effort and
    /// silent on failure.
    static func storeThumbnail(id: String, image: UIImage) {
        guard let downscaled = downscaledThumbnail(image),
              let data = downscaled.jpegData(compressionQuality: 0.8) else { return }
        thumbnailCache.setObject(downscaled, forKey: thumbnailCacheKey(for: id), cost: thumbnailCost(downscaled))
        saveThumbnailToDisk(id: id, data: data)
    }

    /// Downscale to the 400px grid size (aspect-fit, longest side
    /// 400). Images already at or below that size pass through
    /// untouched. Rendered at scale 1 so the result is 400 real
    /// pixels, not 400 points.
    private static func downscaledThumbnail(_ image: UIImage) -> UIImage? {
        let maxSide: CGFloat = 400
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        guard max(size.width, size.height) > maxSide else { return image }
        let scale = maxSide / max(size.width, size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Persist freshly downloaded thumbnail bytes, then evict the
    /// oldest files while the directory is over the cap.
    /// Best-effort and silent.
    private static func saveThumbnailToDisk(id: String, data: Data) {
        guard let url = thumbnailDiskURL(for: id) else { return }
        try? data.write(to: url, options: .atomic)
        evictThumbnailsIfNeeded()
    }

    /// Drop a thumbnail from both cache layers (memory + disk).
    /// Called when its item is deleted, so a later launch never
    /// renders a ghost image from the disk cache (round-27).
    /// Best-effort and silent — a missing file is not an error.
    static func removeCachedThumbnail(id: String) {
        thumbnailCache.removeObject(forKey: thumbnailCacheKey(for: id))
        if let url = thumbnailDiskURL(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
        if let legacyURL = thumbnailLegacyDiskURL(for: id) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    private static func evictThumbnailsIfNeeded() {
        guard let dir = thumbnailDiskDirectory else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { continue }
            entries.append((url, size, date))
            total += size
        }
        guard total > thumbnailDiskCapBytes else { return }
        // Oldest first: a thumbnail file is written once, so its
        // modification date is its save date — evicting the oldest
        // saved is the right order for immutable per-id thumbnails.
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= thumbnailDiskCapBytes { break }
        }
    }

    /// UserDefaults key for the Worker base URL (not a secret).
    static let baseURLDefaultsKey = "kepto.baseURL"

    static var storedBaseURL: String {
        UserDefaults.standard.string(forKey: baseURLDefaultsKey) ?? ""
    }

    static func storeBaseURL(_ url: String) {
        UserDefaults.standard.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLDefaultsKey)
    }

    /// Returns a configured client, or nil when the base URL or API key
    /// has not been entered yet in Settings.
    static func configured() -> KeptoAPI? {
        let rawBase = storedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBase.isEmpty,
              let baseURL = URL(string: rawBase),
              baseURL.scheme == "http" || baseURL.scheme == "https",
              let apiKey = KeychainService.currentAPIKey,
              !apiKey.isEmpty else { return nil }
        return KeptoAPI(baseURL: baseURL, apiKey: apiKey)
    }

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - URL building

    private func url(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // baseURL has no path; append the API path.
        components.path = (components.path as NSString).appendingPathComponent(path)
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url!
    }

    private func authorizedRequest(url: URL, method: String = "GET", jsonBody: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // D1 returns is_favorite as a NUMBER (0/1/null), but Item /
        // ItemMetadata decode it as Bool — JSONDecoder does not decode
        // Bool from numbers, so one 0/1 value fails the whole array
        // (listAll silently emptied For You + Search). Normalize any
        // is_favorite number to a real boolean before decoding, at
        // any depth; if the JSON cannot be walked, decode as-is.
        let normalized = Self.normalizedFavoriteFlags(in: data) ?? data
        return try decoder.decode(type, from: normalized)
    }

    /// Recursively converts `is_favorite` NSNumber values (0/1 from
    /// D1) to real booleans, at any depth. Returns nil when the data
    /// is not a JSON object/array (decode then runs on the raw data).
    /// Real JSON booleans pass through unchanged (NSNumber true/false
    /// round-trips to the same Bool); null stays null (decodes as the
    /// property default).
    private static func normalizedFavoriteFlags(in data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let converted = normalizeFavoriteFlags(json)
        guard JSONSerialization.isValidJSONObject(converted) else { return nil }
        return try? JSONSerialization.data(withJSONObject: converted)
    }

    private static func normalizeFavoriteFlags(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, val) in dict {
                if key == "is_favorite", let number = val as? NSNumber {
                    out[key] = number.boolValue
                } else {
                    out[key] = normalizeFavoriteFlags(val)
                }
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map(normalizeFavoriteFlags)
        }
        return value
    }

    /// Maps an HTTP response to either decoded data or a typed error.
    /// 401 means the API key is wrong; the caller shows the Settings hint.
    private func handle<T: Decodable>(_ data: Data, _ response: URLResponse, as type: T.Type) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw KeptoAPIError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200...299:
            return try decode(type, from: data)
        case 401:
            throw KeptoAPIError.unauthorized
        case 404:
            throw KeptoAPIError.notFound
        default:
            if let errorBody = try? decode(ErrorResponse.self, from: data),
               let message = errorBody.error, !message.isEmpty {
                throw KeptoAPIError.server(message)
            }
            throw KeptoAPIError.server("Worker trả về lỗi \(http.statusCode).")
        }
    }

    // MARK: - Endpoints

    /// GET /api/health — no auth. Used by the Test Connection button.
    func health() async throws -> Bool {
        let (data, response) = try await session.data(from: url(path: "/api/health"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        let body = try decode(HealthResponse.self, from: data)
        return body.ok
    }

    /// GET /api/list — newest first. `platform` / `status` / `q` /
    /// `authorUsername` / `media` are sent only when set; the backend
    /// treats an absent param as "no filter". Pass "__unknown__" as the
    /// username to list items whose creator could not be identified.
    /// `media` is "video" (video only) or "image" (images only).
    func list(platform: Platform? = nil,
              status: ItemStatus? = nil,
              query: String? = nil,
              authorUsername: String? = nil,
              media: String? = nil,
              favorite: Bool? = nil,
              limit: Int = 50,
              cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let platform { items.append(URLQueryItem(name: "platform", value: platform.rawValue)) }
        if let status { items.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let authorUsername { items.append(URLQueryItem(name: "author_username", value: authorUsername)) }
        if let media { items.append(URLQueryItem(name: "media", value: media)) }
        if favorite == true { items.append(URLQueryItem(name: "favorite", value: "1")) }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuery.isEmpty { items.append(URLQueryItem(name: "q", value: trimmedQuery)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/list", queryItems: items)))
        let body = try handle(data, response, as: ListResponse.self)
        return (body.items, body.nextCursor)
    }

    /// GET /api/listAll — light metadata for EVERY item (no
    /// pagination), for complete Years/Months/Days groupings and
    /// synchronous local search. No thumbnail URLs or media bytes —
    /// just the fields the groupings and the Search tab need.
    func listAll() async throws -> [ItemMetadata] {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/listAll")))
        let body = try handle(data, response, as: ListAllResponse.self)
        return body.items
    }

    /// GET /api/stats — library counts for the Photos-style header
    /// ("N Photos, M Videos") and the Albums tab (Recents = total,
    /// Favorites = favorites). Throws so the caller can fall back to
    /// hiding the counts when the endpoint is unavailable.
    func stats() async throws -> LibraryStats {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/stats")))
        let body = try handle(data, response, as: StatsResponse.self)
        return LibraryStats(total: body.total, photos: body.photos, videos: body.videos, favorites: body.favorites)
    }

    /// GET /api/collections — one row per creator username, newest first.
    func collections() async throws -> [CollectionInfo] {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/collections")))
        let body = try handle(data, response, as: CollectionsResponse.self)
        return body.collections
    }

    /// GET /api/items/:id
    func getItem(id: String) async throws -> Item {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/items/\(id)")))
        let body = try handle(data, response, as: ItemResponse.self)
        return body.item
    }

    /// POST /api/save — returns 202 with the new item in `pending` status.
    /// The ingest service runs in the background; the item becomes `ready`
    /// later. Throws `.invalidURL` for a non-http(s) link before any call.
    /// When the link was already saved, the backend returns the existing
    /// item with `duplicate: true` instead of a second copy.
    /// POST /api/save — save one link. The Worker auto-detects a
    /// Collection link (full or short — short links are resolved
    /// first) and saves the whole collection instead, so this returns
    /// either a single video or a collection. The request gets a 120s
    /// timeout because expanding a collection takes ~5-30s.
    func save(url rawURL: String) async throws -> SaveOutcome {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              parsed.scheme == "http" || parsed.scheme == "https" else {
            throw KeptoAPIError.invalidURL
        }
        let body = try JSONSerialization.data(withJSONObject: ["url": trimmed])
        var request = authorizedRequest(url: url(path: "/api/save"), method: "POST", jsonBody: body)
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        // A single save returns { item, ... }; a collection save
        // returns { total, created, items, ... } with no `item` key.
        // (Non-2xx errors throw from handle either way, so a failed
        // single-decode here can only mean a collection response.)
        if let single = try? handle(data, response, as: SaveResponse.self) {
            return .single(SaveResult(item: single.item, duplicate: single.duplicate ?? false, retried: single.retried ?? false))
        }
        let coll = try handle(data, response, as: SaveCollectionResponse.self)
        return .collection(SaveCollectionResult(
            title: coll.title,
            total: coll.total ?? 0,
            created: coll.created ?? 0,
            duplicates: coll.duplicates ?? 0,
            capped: coll.capped ?? false,
            collectionId: coll.collectionId,
            items: coll.items ?? []
        ))
    }

    /// POST /api/upload — upload a photo/video from the device Albums.
    /// The file is sent as the raw request body (Content-Type = the
    /// file's MIME type, filename in ?filename=); the Worker creates a
    /// pending "album" item, streams the body to the ingest service for
    /// processing, and returns the finished item. The request gets a
    /// 600s timeout because a large video upload + processing takes a
    /// while. Photos are converted to JPEG by the caller before this
    /// (the ingest cannot convert HEIC — iPhone photos are HEIC).
    /// `sha256` is the SHA-256 of the exact bytes being uploaded (the
    /// caller computes it); when it matches an item already saved, the
    /// Worker returns that item with `duplicate: true` instead of
    /// uploading again. Returns the item and whether it was a duplicate.
    /// `onProgress` (0...1, byte-based) is called from the URLSession
    /// delegate queue — the caller must hop to the main actor before
    /// touching UI state. Nil = the old path (`session.upload`, no
    /// progress). Timeout, auth headers, fromFile body and the return
    /// type are identical either way.
    func uploadFile(fileURL: URL, filename: String, mimeType: String, sha256: String? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> (item: Item, duplicate: Bool) {
        var query = [URLQueryItem(name: "filename", value: filename)]
        if let sha256, !sha256.isEmpty {
            query.append(URLQueryItem(name: "sha256", value: sha256))
        }
        var request = authorizedRequest(url: url(path: "/api/upload", queryItems: query), method: "POST")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (data, response): (Data, URLResponse)
        if let onProgress {
            (data, response) = try await uploadWithProgress(request: request, fileURL: fileURL, onProgress: onProgress)
        } else {
            (data, response) = try await session.upload(for: request, fromFile: fileURL)
        }
        let decoded = try handle(data, response, as: ItemResponse.self)
        return (decoded.item, decoded.duplicate ?? false)
    }

    /// Upload with byte progress. `URLSession.shared` cannot take a
    /// delegate, so this builds a one-shot session around an
    /// `UploadProgressDelegate` and bridges it to async/await with a
    /// continuation (resumed exactly once, in didCompleteWithError).
    /// The session is invalidated when the task completes. Cancelling
    /// the awaiting task cancels the upload task too.
    private func uploadWithProgress(request: URLRequest, fileURL: URL, onProgress: @escaping (Double) -> Void) async throws -> (Data, URLResponse) {
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.uploadTask(with: request, fromFile: fileURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                delegate.onComplete = { result in continuation.resume(with: result) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// DELETE /api/items/:id
    func delete(id: String) async throws {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/items/\(id)"), method: "DELETE"))
        try checkDeleteResponse(data, response)
    }

    /// POST /api/items/:id/favorite — heart / unheart an item. Returns
    /// the updated item. Needs migration 0005 on the backend; without
    /// it the Worker returns an error.
    func setFavorite(id: String, favorite: Bool) async throws -> Item {
        let body = try JSONSerialization.data(withJSONObject: ["favorite": favorite])
        let (data, response) = try await session.data(
            for: authorizedRequest(url: url(path: "/api/items/\(id)/favorite"), method: "POST", jsonBody: body)
        )
        let decoded = try handle(data, response, as: FavoriteResponse.self)
        return decoded.item
    }

    /// Shared response handling for the DELETE endpoints (delete item,
    /// remove from a collection, delete a collection): 2xx = done,
    /// 401/404 map to the typed errors, anything else to the server's
    /// message when it has one.
    private func checkDeleteResponse(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw KeptoAPIError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw KeptoAPIError.unauthorized
        case 404:
            throw KeptoAPIError.notFound
        default:
            if let errorBody = try? decode(ErrorResponse.self, from: data),
               let message = errorBody.error, !message.isEmpty {
                throw KeptoAPIError.server(message)
            }
            throw KeptoAPIError.server("Worker trả về lỗi \(http.statusCode).")
        }
    }

    // MARK: - My collections (user-created lists)

    /// GET /api/my-collections — user-created collections, newest first.
    func myCollections() async throws -> [MyCollection] {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections")))
        let body = try handle(data, response, as: MyCollectionsResponse.self)
        return body.collections
    }

    /// POST /api/my-collections — create a collection by name.
    func createMyCollection(name: String) async throws -> MyCollection {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections"), method: "POST", jsonBody: body))
        let decoded = try handle(data, response, as: MyCollectionResponse.self)
        return decoded.collection
    }

    /// POST /api/my-collections/:id/items — add a video. Returns true
    /// when it was newly added, false when it was already there.
    func addItemToMyCollection(collectionId: String, itemId: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["item_id": itemId])
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections/\(collectionId)/items"), method: "POST", jsonBody: body))
        let decoded = try handle(data, response, as: AddToCollectionResponse.self)
        return decoded.added ?? false
    }

    /// GET /api/my-collections/:id/items — videos in a collection,
    /// newest-added first.
    func myCollectionItems(collectionId: String,
                           limit: Int = 50,
                           cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections/\(collectionId)/items", queryItems: items)))
        let body = try handle(data, response, as: ListResponse.self)
        return (body.items, body.nextCursor)
    }

    /// DELETE /api/my-collections/:id/items/:itemId — remove a video
    /// from a collection (the item itself stays saved in the library).
    func removeItemFromMyCollection(collectionId: String, itemId: String) async throws {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections/\(collectionId)/items/\(itemId)"), method: "DELETE"))
        try checkDeleteResponse(data, response)
    }

    /// PATCH /api/my-collections/:id — rename a collection.
    func renameMyCollection(id: String, name: String) async throws -> MyCollection {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections/\(id)"), method: "PATCH", jsonBody: body))
        let decoded = try handle(data, response, as: MyCollectionResponse.self)
        return decoded.collection
    }

    /// DELETE /api/my-collections/:id — delete the collection. When
    /// deleteItems is true, also deletes the videos that live only in
    /// this album (R2 media + D1 rows); a video that is also in
    /// another album stays saved.
    func deleteMyCollection(id: String, deleteItems: Bool = false) async throws {
        var queryItems: [URLQueryItem] = []
        if deleteItems { queryItems.append(URLQueryItem(name: "delete_items", value: "1")) }
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections/\(id)", queryItems: queryItems), method: "DELETE"))
        try checkDeleteResponse(data, response)
    }

    /// DELETE /api/collections/:username — delete a whole creator
    /// album. A creator collection is derived from its videos, so
    /// this permanently deletes every video by that creator
    /// (R2 media + D1 rows). There is no "album only" variant.
    func deleteCreatorCollection(username: String) async throws {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/collections/\(encoded)"), method: "DELETE"))
        try checkDeleteResponse(data, response)
    }

    // MARK: - Authenticated media URLs

    /// URL for GET /api/play/:id. The Bearer token is NOT in the URL —
    /// see `PhotoDetailView`: it is passed via
    /// `AVURLAssetHTTPHeaderFieldsKey` when building the AVURLAsset.
    /// The Worker has no redirects, so the header survives the whole stream.
    func playURL(for item: Item) -> URL {
        url(path: "/api/play/\(item.id)")
    }

    /// Authorization header value for media requests (play + thumbnail).
    var authorizationHeader: String { "Bearer \(apiKey)" }

    /// GET /api/thumb/:id with the Authorization header.
    /// AsyncImage cannot send custom headers, so thumbnails are loaded
    /// with URLSession here. Three layers (round-23): the shared
    /// NSCache (this session), the disk cache under Caches/thumbnails
    /// (survives restarts), then the network. The app is cloud-only
    /// for media — the disk layer holds only small preview images,
    /// never originals.
    func fetchThumbnail(for item: Item) async throws -> UIImage? {
        try await fetchThumbnail(id: item.id)
    }

    func fetchThumbnail(id: String) async throws -> UIImage? {
        // Layer 1: memory (smooth scrolling with thousands of items
        // — no re-download on scroll-back).
        if let cached = Self.thumbnailCache.object(forKey: Self.thumbnailCacheKey(for: id)) {
            return cached
        }
        // Layer 2: disk (survives app restarts — the grid opens with
        // real thumbnails instead of gray placeholders).
        if let disk = Self.thumbnailFromDisk(id: id) {
            Self.thumbnailCache.setObject(disk, forKey: Self.thumbnailCacheKey(for: id), cost: Self.thumbnailCost(disk))
            return disk
        }
        // Layer 3: network.
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/thumb/\(id)")))
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        // Round-32: downscale to the 400px grid size + JPEG 0.8 before
        // caching, exactly like storeThumbnail does at save time. The
        // old code cached the raw Worker bytes and the raw decoded
        // image, so an oversized Worker thumbnail landed full-size in
        // the NSCache (inflated cost) and on disk (unbounded bytes)
        // and was decoded at full size for every grid cell.
        let thumb = Self.downscaledThumbnail(image) ?? image
        Self.thumbnailCache.setObject(thumb, forKey: Self.thumbnailCacheKey(for: id), cost: Self.thumbnailCost(thumb))
        Self.saveThumbnailToDisk(id: id, data: thumb.jpegData(compressionQuality: 0.8) ?? data)
        return thumb
    }

    /// GET /api/preview/:id — the scrub-preview sprite (tile grid of
    /// thumbnails). Same auth as thumbnails; unlike thumbnails,
    /// sprites are NOT persisted to disk. Returns nil when the item
    /// has no sprite (older saves, or the sprite step failed during
    /// ingest).
    func fetchSprite(for item: Item) async throws -> UIImage? {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/preview/\(item.id)")))
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return UIImage(data: data)
    }

    /// Downloads the video file (authenticated, GET /api/play/:id)
    /// to a temp file and returns its URL. Used by the feed's
    /// long-press Download (the file is then saved to Photos).
    /// The file lives in the temp directory — use it promptly, the
    /// system may clean it up.
    func downloadVideoFile(for item: Item) async throws -> URL {
        let (tmpURL, response) = try await session.download(for: authorizedRequest(url: playURL(for: item)))
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw KeptoAPIError.server("Worker trả về lỗi \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(item.id).\(fileExtension(for: item))")
        // Drop a stale copy from an earlier download of this item.
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        return dest
    }

    /// Tải file có track tiến trình (0...1). Dùng URLSessionDownloadDelegate
    /// thay vì session.download(for:) vì hàm cũ không báo được %.
    func downloadVideoFileWithProgress(for item: Item, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let request = authorizedRequest(url: playURL(for: item))
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.onComplete = { result in
                    switch result {
                    case .success(let tmpURL):
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("\(item.id).\(self.fileExtension(for: item))")
                        try? FileManager.default.removeItem(at: dest)
                        do {
                            try FileManager.default.moveItem(at: tmpURL, to: dest)
                            continuation.resume(returning: dest)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// File extension for a downloaded item, from its content type.
    /// Image posts (photo posts) come back as image/* — they must keep
    /// an image extension so Photos / the share sheet treat them as
    /// photos, not as a misnamed .mp4.
    private func fileExtension(for item: Item) -> String {
        if let contentType = item.contentType?.lowercased() {
            if contentType.contains("mp4") { return "mp4" }
            if contentType.contains("mov") || contentType.contains("quicktime") { return "mov" }
            if contentType.contains("webm") { return "webm" }
            if contentType.contains("mkv") { return "mkv" }
            if contentType.contains("jpeg") || contentType.contains("jpg") { return "jpg" }
            if contentType.contains("png") { return "png" }
            if contentType.contains("webp") { return "webp" }
            if contentType.contains("gif") { return "gif" }
            if contentType.contains("heic") { return "heic" }
        }
        return "mp4"
    }
}

/// Delegate for one upload-with-progress session (see
/// `KeptoAPI.uploadWithProgress`). `URLSessionUploadTask` is a data
/// task, so the response body arrives through the data-delegate
/// methods and completion through `didCompleteWithError` — which
/// resumes the awaiting continuation exactly once. All callbacks run
/// on the session's serial delegate queue (delegateQueue nil), so
/// `receivedData` / `response` need no extra locking; `onProgress`
/// is called on that same queue and the caller hops to the main
/// actor. The session is invalidated in `didCompleteWithError`, which
/// also releases this delegate.
private final class UploadProgressDelegate: NSObject, URLSessionDataDelegate {
    private let onProgress: (Double) -> Void
    var onComplete: (Result<(Data, URLResponse), Error>) -> Void = { _ in }
    private var receivedData = Data()
    private var response: URLResponse?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            onComplete(.failure(error))
            return
        }
        guard let response else {
            onComplete(.failure(URLError(.badServerResponse)))
            return
        }
        onComplete(.success((receivedData, response)))
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    var onComplete: (Result<URL, Error>) -> Void = { _ in }

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Phải move file ngay trong hàm này, vì file tạm sẽ bị xoá sau khi return
        let tempDest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempDest)
            onComplete(.success(tempDest))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error {
            onComplete(.failure(error))
        }
    }
}
