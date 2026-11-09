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
/// playback streams from the Worker and thumbnails are kept in memory only.
final class KeptoAPI {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

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
        return try decoder.decode(type, from: data)
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
              limit: Int = 50,
              cursor: String? = nil) async throws -> (items: [Item], nextCursor: String?) {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let platform { items.append(URLQueryItem(name: "platform", value: platform.rawValue)) }
        if let status { items.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let authorUsername { items.append(URLQueryItem(name: "author_username", value: authorUsername)) }
        if let media { items.append(URLQueryItem(name: "media", value: media)) }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuery.isEmpty { items.append(URLQueryItem(name: "q", value: trimmedQuery)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/list", queryItems: items)))
        let body = try handle(data, response, as: ListResponse.self)
        return (body.items, body.nextCursor)
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

    /// DELETE /api/my-collections/:id — delete the collection (the
    /// videos in it stay saved in the library).
    func deleteMyCollection(id: String) async throws {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/my-collections/\(id)"), method: "DELETE"))
        try checkDeleteResponse(data, response)
    }

    // MARK: - Authenticated media URLs

    /// URL for GET /api/play/:id. The Bearer token is NOT in the URL —
    /// see `ItemDetailView`: it is passed via
    /// `AVURLAssetHTTPHeaderFieldsKey` when building the AVURLAsset.
    /// The Worker has no redirects, so the header survives the whole stream.
    func playURL(for item: Item) -> URL {
        url(path: "/api/play/\(item.id)")
    }

    /// Authorization header value for media requests (play + thumbnail).
    var authorizationHeader: String { "Bearer \(apiKey)" }

    /// GET /api/thumb/:id with the Authorization header.
    /// AsyncImage cannot send custom headers, so thumbnails are loaded
    /// with URLSession here and kept in memory only (no disk cache —
    /// the app is cloud-only by design).
    func fetchThumbnail(for item: Item) async throws -> UIImage? {
        try await fetchThumbnail(id: item.id)
    }

    func fetchThumbnail(id: String) async throws -> UIImage? {
        let (data, response) = try await session.data(for: authorizedRequest(url: url(path: "/api/thumb/\(id)")))
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return UIImage(data: data)
    }

    /// GET /api/preview/:id — the scrub-preview sprite (tile grid of
    /// thumbnails). Same auth + memory-only handling as thumbnails.
    /// Returns nil when the item has no sprite (older saves, or the
    /// sprite step failed during ingest).
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

    private func fileExtension(for item: Item) -> String {
        if let contentType = item.contentType?.lowercased() {
            if contentType.contains("mp4") { return "mp4" }
            if contentType.contains("mov") || contentType.contains("quicktime") { return "mov" }
            if contentType.contains("webm") { return "webm" }
            if contentType.contains("mkv") { return "mkv" }
        }
        return "mp4"
    }
}
