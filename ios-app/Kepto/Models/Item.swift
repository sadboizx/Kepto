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
struct Item: Codable, Identifiable, Equatable {
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
    let isFavorite: Bool = false
    let status: ItemStatus
    let ingestError: String?
    let createdAt: String

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

    private static let isoFormatter = ISO8601DateFormatter()

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
}

struct FavoriteResponse: Decodable {
    let ok: Bool
    let item: Item
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
