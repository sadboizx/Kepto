import Foundation

/// Platform values match the Worker backend exactly (see worker/db.ts:
/// `detectPlatform`). The backend returns them as snake_case JSON strings,
/// decoded here with `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`.
enum Platform: String, Codable, CaseIterable, Identifiable {
    case tiktok
    case instagram
    case threads
    case x
    case facebook
    case douyin
    case youtube
    case album
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .threads: return "Threads"
        case .x: return "X"
        case .facebook: return "Facebook"
        case .douyin: return "Douyin"
        case .youtube: return "YouTube"
        case .album: return "Albums"
        case .other: return "Other"
        }
    }

    /// Short label used in list rows.
    var shortName: String { displayName }
}

enum ItemStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case ready
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

/// One saved social post. Field names are camelCase; the JSON decoder
/// converts the backend's snake_case keys (`original_url`, `saved_at`, ...).
/// Hashable so the player can be pushed with
/// `.navigationDestination(item:)` (the native iOS back gesture),
/// like CollectionInfo and MyCollection in this file.
struct Item: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let userId: String
    let platform: Platform
    let originalUrl: String
    let r2Key: String?
    let thumbKey: String?
    let previewKey: String?
    let contentType: String?
    let title: String?
    let caption: String?
    let author: String?
    let authorUsername: String?
    let authorAvatarUrl: String?
    let postedAt: String?
    let savedAt: String
    let duration: Double?
    let width: Int?
    let height: Int?
    let fileSize: Int?
    let sha256: String?
    let previewCols: Int?
    let previewRows: Int?
    let previewInterval: Double?
    let previewCount: Int?
    /// View count from the extractor (TikTok), when the metadata probe
    /// could read it. Null for older saves and for probes that failed.
    let viewCount: Int?
    /// True when the item is favorited (heart). Defaults to false when
    /// the key is missing (the backend only sends it after migration
    /// 0005) — a missing key must never fail decoding the whole item.
    var isFavorite: Bool = false
    let status: ItemStatus
    let ingestError: String?
    let createdAt: String
    /// Upload progress of a LOCAL placeholder item (0...1) while a
    /// file is uploading from the device. Nil for every server item.
    /// `var` with a default, like isFavorite: the synthesized
    /// memberwise init omits it (assign on the copy after init), and
    /// the synthesized Codable decode treats a missing key as nil.
    /// The grid ring reads it via `GridItemSource.uploadProgress`.
    var uploadProgress: Double? = nil

    /// Best human-readable title: title, else caption, else the URL itself.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return caption
        }
        return originalUrl
    }

    var displayAuthor: String {
        guard let author, !author.isEmpty else { return platform.displayName }
        return author
    }

    /// Collection name for this item: @username, else the author name,
    /// else "Unknown" (items whose creator could not be identified).
    var collectionName: String {
        if let authorUsername, !authorUsername.isEmpty { return "@\(authorUsername)" }
        if let author, !author.isEmpty { return author }
        return "Unknown"
    }

    /// True when the ingest service generated a scrub-preview sprite for
    /// this item (all four geometry values present). The player uses it to
    /// show a frame preview while the user drags the progress bar.
    var hasScrubSprite: Bool {
        previewKey != nil
            && (previewCols ?? 0) > 0
            && (previewRows ?? 0) > 0
            && (previewInterval ?? 0) > 0
            && (previewCount ?? 0) > 0
    }

    /// Human-readable version of ingestError. The stored error is a
    /// machine code (e.g. cobalt_error.api.content.post.age); this
    /// translates the known ones into plain language. Unknown errors
    /// are shown as-is.
    var friendlyIngestError: String {
        guard let error = ingestError else { return "Unknown error." }
        if error.contains("post.age")
            || error.contains("Log in for access")
            || error.contains("comfortable for some audiences") {
            return "Video này bị giới hạn độ tuổi (18+) — TikTok yêu cầu đăng nhập mới xem được nên Kepto không tải được. Thử lưu video khác không bị giới hạn."
        }
        if error.contains("audio_only_no_video") {
            return "Bài đăng này chỉ có âm thanh, không có video — Kepto chỉ lưu video nên không lưu được bài này."
        }
        if error.contains("post.unavailable") {
            return "Bài đăng không còn khả dụng (đã bị xóa hoặc để riêng tư)."
        }
        if error.contains("Unexpected response from webpage request") {
            return "TikTok không trả về trang video cho máy chủ (thường là video bị giới hạn tuổi hoặc TikTok đang chặn IP máy chủ). Thử lưu video khác hoặc thử lại sau."
        }
        return error
    }

    /// View count formatted TikTok-style: 584, 1,395, 20.2K.
    var formattedViewCount: String? {
        guard let viewCount else { return nil }
        if viewCount >= 10_000 {
            let k = Double(viewCount) / 1000
            var s = String(format: "%.1f", k)
            if s.hasSuffix(".0") { s = String(s.dropLast(2)) }
            return s + "K"
        }
        return Self.groupingFormatter.string(from: NSNumber(value: viewCount))
    }

    private static let groupingFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// Duration in seconds formatted as m:ss, e.g. 52 -> "0:52".
    var formattedDuration: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// File size formatted for humans, e.g. 4.2 MB.
    var formattedFileSize: String? {
        guard let fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    /// "854 x 480" when dimensions are known.
    var formattedDimensions: String? {
        guard let width, let height else { return nil }
        return "\(width) x \(height)"
    }

    // D1 stores saved_at with fractional seconds
    // (strftime '%Y-%m-%dT%H:%M:%fZ'), and the default
    // ISO8601DateFormatter does NOT parse those — savedDate came back
    // nil for every row, so sortDate silently fell back to postedDate
    // (and uploads, posted_at null, to .distantPast = oldest = top).
    // .withFractionalSeconds parses both forms.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func displayDate(_ isoString: String?) -> String? {
        guard let isoString,
              let date = isoFormatter.date(from: isoString) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedSavedAt: String? { Self.displayDate(savedAt) }
    var formattedPostedAt: String? { Self.displayDate(postedAt) }

    /// The saved date as a Date (for the Library Years/Months/Days
    /// grouping and the For You memories). Nil when the stored
    /// ISO string does not parse.
    var savedDate: Date? { Self.isoFormatter.date(from: savedAt) }

    /// The posted date as a Date (nil when postedAt is missing or
    /// unparsable). Used by the Player info sheet.
    var postedDate: Date? { postedAt.flatMap { Self.isoFormatter.date(from: $0) } }

    /// Save/import date (the sort key): when the item was saved
    /// into Kepto, else the original post date. Items with no
    /// parseable date sort as the oldest (.distantPast) — they never
    /// crash the sort.
    var sortDate: Date { savedDate ?? postedDate ?? .distantPast }

    /// Capture date (the sort key for Years/Months/Days): the
    /// original post date is the closest thing to when the
    /// photo/video was taken, else when it was saved into Kepto.
    /// Uploads have postedAt null, so they fall back to savedDate.
    var creationDate: Date { postedDate ?? savedDate ?? .distantPast }
}

/// Light metadata for one item (GET /api/listAll). Everything the
/// Library groupings, Memories, Featured and local search need — and
/// nothing more: no R2 keys, no thumbnail URLs, no media bytes. The
/// full Item is still fetched per id when the UI needs it (play,
/// share, Save to Photos).
struct ItemMetadata: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let platform: Platform
    let title: String?
    let caption: String?
    let author: String?
    let authorUsername: String?
    let postedAt: String?
    let savedAt: String
    let contentType: String?
    let duration: Double?
    let width: Int?
    let height: Int?
    let fileSize: Int?
    /// True when favorited (heart). Defaults to false when the key
    /// is missing — same rule as Item.isFavorite.
    /// `var` (not `let`): a `let` with an inline default cannot be
    /// assigned again inside an initializer, so the explicit init
    /// below could not set it — the compiler errors with
    /// "immutable value may only be initialized once".
    var isFavorite: Bool = false
    /// User-created collections this item is in (ids + names).
    /// Empty when the item is in no My collection.
    /// `var` for the same reason as isFavorite above.
    var myCollectionIds: [String] = []
    var myCollectionNames: [String] = []
    /// Upload progress of a LOCAL placeholder item (0...1) — the
    /// metadata twin of `Item.uploadProgress`, so the Library grid
    /// (which renders from metadata) can show the same ring. Nil
    /// for every server item; never persisted (placeholders are
    /// filtered out of the disk cache).
    var uploadProgress: Double? = nil

    /// Full memberwise initializer. The synthesized one only takes
    /// the 13 properties without defaults, so a call site that must
    /// also set the favorite flag / collection membership — e.g.
    /// upsertMetadata keeping the heart and the My-collection
    /// membership when an item refreshes — needs this explicit init.
    /// The last three default, so JSON decoding and plain
    /// construction keep working unchanged.
    init(
        id: String,
        platform: Platform,
        title: String?,
        caption: String?,
        author: String?,
        authorUsername: String?,
        postedAt: String?,
        savedAt: String,
        contentType: String?,
        duration: Double?,
        width: Int?,
        height: Int?,
        fileSize: Int?,
        isFavorite: Bool = false,
        myCollectionIds: [String] = [],
        myCollectionNames: [String] = []
    ) {
        self.id = id
        self.platform = platform
        self.title = title
        self.caption = caption
        self.author = author
        self.authorUsername = authorUsername
        self.postedAt = postedAt
        self.savedAt = savedAt
        self.contentType = contentType
        self.duration = duration
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.isFavorite = isFavorite
        self.myCollectionIds = myCollectionIds
        self.myCollectionNames = myCollectionNames
    }

    /// Round-26: build metadata straight from a freshly uploaded
    /// Item, so the caches gain the new item immediately (no listAll
    /// round trip). Collection membership is unknown at upload time
    /// — empty until the next listAll refresh fills it in.
    init(from item: Item) {
        self.init(
            id: item.id,
            platform: item.platform,
            title: item.title,
            caption: item.caption,
            author: item.author,
            authorUsername: item.authorUsername,
            postedAt: item.postedAt,
            savedAt: item.savedAt,
            contentType: item.contentType,
            duration: item.duration,
            width: item.width,
            height: item.height,
            fileSize: item.fileSize,
            isFavorite: item.isFavorite
        )
    }

    // D1 stores saved_at with fractional seconds
    // (strftime '%Y-%m-%dT%H:%M:%fZ'), and the default
    // ISO8601DateFormatter does NOT parse those — savedDate came back
    // nil for every row, so sortDate silently fell back to postedDate
    // (and uploads, posted_at null, to .distantPast = oldest = top).
    // .withFractionalSeconds parses both forms.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The saved date as a Date (for groupings + Memories). Nil
    /// when the stored ISO string does not parse.
    var savedDate: Date? { Self.isoFormatter.date(from: savedAt) }

    /// The posted date as a Date (nil when missing/unparsable).
    var postedDate: Date? { postedAt.flatMap { Self.isoFormatter.date(from: $0) } }

    /// Save/import date (the sort key): when the item was saved
    /// into Kepto, else the original post date. Items with no
    /// parseable date sort as the oldest (.distantPast) — they never
    /// crash the sort.
    var sortDate: Date { savedDate ?? postedDate ?? .distantPast }

    /// Capture date (the sort key for Years/Months/Days): the
    /// original post date is the closest thing to when the
    /// photo/video was taken, else when it was saved into Kepto.
    /// Uploads have postedAt null, so they fall back to savedDate.
    var creationDate: Date { postedDate ?? savedDate ?? .distantPast }

    var displayAuthor: String {
        guard let author, !author.isEmpty else { return platform.displayName }
        return author
    }

    /// Collection name for this item: @username, else the author
    /// name, else "Unknown" — same rule as Item.collectionName.
    var collectionName: String {
        if let authorUsername, !authorUsername.isEmpty { return "@\(authorUsername)" }
        if let author, !author.isEmpty { return author }
        return "Unknown"
    }
}

/// GET /api/listAll response envelope.
struct ListAllResponse: Decodable {
    let ok: Bool
    let items: [ItemMetadata]
    let total: Int?
}

// MARK: - API response envelopes (backend returns { ok, ... })

struct ListResponse: Decodable {
    let ok: Bool
    let items: [Item]
    let nextCursor: String?
}

struct ItemResponse: Decodable {
    let ok: Bool
    let item: Item
    /// True when /api/upload found this content already saved: the
    /// app sent the file's SHA-256 and it matched an existing item,
    /// so the Worker returned that item instead of uploading again.
    /// Absent (nil) for /api/save and for a fresh upload.
    let duplicate: Bool?
}

struct FavoriteResponse: Decodable {
    let ok: Bool
    let item: Item
}

// MARK: - Chronological order (Apple Photos: oldest first, newest last)

/// Shared ascending sort for every chronological grid (Library +
/// album details): by date taken, oldest first. Equal timestamps
/// tie-break on the stable id, so the order never shuffles between
/// renders. Kept here (not scattered per screen) so all grids agree.
extension Array where Element == Item {
    func sortedChronologically() -> [Item] {
        // Round-29: sortDate parses an ISO8601 string on EVERY access,
        // and the comparator reads it ~log N times per element — for a
        // 117-item album that was ~1600 parses on the main thread in
        // onAppear, between tap and push (~1s stall; <10 items were
        // instant). Parse once per element, sort the pairs, drop the
        // keys. Order is identical: (date, id), oldest first.
        map { ($0, $0.sortDate) }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
            .map { $0.0 }
    }

    /// Same order, by capture date instead of save date (Years /
    /// Months / Days groupings).
    func sortedByCreationDate() -> [Item] {
        // Round-29: same one-parse-per-element fix as above.
        map { ($0, $0.creationDate) }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
            .map { $0.0 }
    }
}

extension Array where Element == ItemMetadata {
    func sortedChronologically() -> [ItemMetadata] {
        // Round-29: same one-parse-per-element fix as Item above —
        // this is the sort the album seed runs (all 117 rows).
        map { ($0, $0.sortDate) }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
            .map { $0.0 }
    }

    /// Same order, by capture date instead of save date (Years /
    /// Months / Days groupings).
    func sortedByCreationDate() -> [ItemMetadata] {
        // Round-29: same one-parse-per-element fix as Item above.
        map { ($0, $0.creationDate) }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
            .map { $0.0 }
    }
}

struct SaveResponse: Decodable {
    let ok: Bool
    let item: Item
    let ingestConfigured: Bool?
    /// True when the link was already saved — no second copy was made.
    let duplicate: Bool?
    /// True when a previously failed save was retried (back to pending).
    let retried: Bool?
}

/// Result of POST /api/save: the item plus whether it was already saved.
struct SaveResult {
    let item: Item
    let duplicate: Bool
    let retried: Bool
}

/// Result of POST /api/save. The Worker auto-detects a Collection link
/// (full or short), so one save call returns either a single video or
/// a whole collection — the app shows the matching notice.
enum SaveOutcome {
    case single(SaveResult)
    case collection(SaveCollectionResult)
}

struct SaveCollectionResponse: Decodable {
    let ok: Bool
    let title: String?
    let total: Int?
    let created: Int?
    let duplicates: Int?
    let capped: Bool?
    let collectionId: String?
    let items: [Item]?
}

/// Result of POST /api/save-collection: how many videos the collection
/// held, how many were new, and the items themselves.
struct SaveCollectionResult {
    let title: String?
    let total: Int
    let created: Int
    let duplicates: Int
    let capped: Bool
    let collectionId: String?
    let items: [Item]
}

/// One collection: all saved items from one creator username.
/// `authorUsername` is nil for the "Unknown" collection (creator not identified).
struct CollectionInfo: Codable, Identifiable, Equatable, Hashable {
    let authorUsername: String?
    let author: String?
    let count: Int
    let coverItemId: String?
    let latestSavedAt: String

    /// The id used for the /api/list filter: the username, or the
    /// "__unknown__" sentinel the backend treats as NULL username.
    var id: String { authorUsername ?? "__unknown__" }

    var displayName: String {
        if let authorUsername, !authorUsername.isEmpty { return "@\(authorUsername)" }
        if let author, !author.isEmpty { return author }
        return "Unknown"
    }
}

struct CollectionsResponse: Decodable {
    let ok: Bool
    let collections: [CollectionInfo]
}

/// GET /api/stats response envelope (backend returns { ok, total,
/// photos, videos, favorites }).
struct StatsResponse: Decodable {
    let ok: Bool
    let total: Int
    let photos: Int
    let videos: Int
    let favorites: Int
}

/// Library counts for the Photos-style header ("N Photos, M Videos")
/// and the Albums tab (Recents = total, Favorites = favorites).
struct LibraryStats: Equatable {
    let total: Int
    let photos: Int
    let videos: Int
    let favorites: Int
}

/// One user-created collection ("My collections", TikTok-style "Add to
/// collection"). Unlike the per-creator collections (automatic, one per
/// username), these are lists the user creates and adds videos to by
/// hand. `coverItemId` is the newest video with a thumbnail.
struct MyCollection: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let count: Int
    let coverItemId: String?
    let createdAt: String
}

struct MyCollectionsResponse: Decodable {
    let ok: Bool
    let collections: [MyCollection]
}

struct MyCollectionResponse: Decodable {
    let ok: Bool
    let collection: MyCollection
}

/// Result of POST /api/my-collections/:id/items: `added` is false when
/// the video was already in the collection (no second copy).
struct AddToCollectionResponse: Decodable {
    let ok: Bool
    let added: Bool?
    let duplicate: Bool?
}

struct HealthResponse: Decodable {
    let ok: Bool
    let service: String?
}

struct ErrorResponse: Decodable {
    let ok: Bool
    let error: String?
}

/// Seed constructor from the light `listAll` cache (round-21): builds
/// a display-only Item so an album can render instantly from cached
/// metadata while the first page loads (stale-while-revalidate).
/// Everything the grid and the viewer need resolves by id —
/// thumbnails (`fetchThumbnail(id:)`), playback (`playURL` =
/// /api/play/<id>), share/save (`downloadVideoFile` via playURL) — so
/// the missing R2 keys do not matter. The background fetch replaces
/// these seeds with the real Items (same ids, same order) within ~a
/// second; `status` is assumed `.ready` and `userId` / `originalUrl`
/// are unknown until then. (An extension init, so the synthesized
/// memberwise init stays available — a custom init inside the struct
/// would remove it and break `withFavorite`.)
extension Item {
    init(seededFrom metadata: ItemMetadata) {
        self.init(
            id: metadata.id,
            userId: "",
            platform: metadata.platform,
            originalUrl: "",
            r2Key: nil,
            thumbKey: nil,
            previewKey: nil,
            contentType: metadata.contentType,
            title: metadata.title,
            caption: metadata.caption,
            author: metadata.author,
            authorUsername: metadata.authorUsername,
            authorAvatarUrl: nil,
            postedAt: metadata.postedAt,
            savedAt: metadata.savedAt,
            duration: metadata.duration,
            width: metadata.width,
            height: metadata.height,
            fileSize: metadata.fileSize,
            sha256: nil,
            previewCols: nil,
            previewRows: nil,
            previewInterval: nil,
            previewCount: nil,
            viewCount: nil,
            status: .ready,
            ingestError: nil,
            createdAt: metadata.savedAt
        )
        self.isFavorite = metadata.isFavorite
    }
}
