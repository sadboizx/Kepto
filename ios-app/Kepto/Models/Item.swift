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
        if error.contains("post.unavailable") {
            return "Bài đăng không còn khả dụng (đã bị xóa hoặc để riêng tư)."
        }
        if error.contains("Unexpected response from webpage request") {
            return "TikTok không trả về trang video cho máy chủ (thường là video bị giới hạn tuổi hoặc TikTok đang chặn IP máy chủ). Thử lưu video khác hoặc thử lại sau."
        }
        return error
    }

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

/// One collection: all saved items from one creator username.
/// `authorUsername` is nil for the "Unknown" collection (creator not identified).
struct CollectionInfo: Codable, Identifiable, Equatable {
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

struct HealthResponse: Decodable {
    let ok: Bool
    let service: String?
}

struct ErrorResponse: Decodable {
    let ok: Bool
    let error: String?
}
