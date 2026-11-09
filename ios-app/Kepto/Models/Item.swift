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
    let authorAvatarUrl: String?
    let postedAt: String?
    let savedAt: String
    let duration: Double?
    let width: Int?
    let height: Int?
    let fileSize: Int?
    let sha256: String?
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
}

struct HealthResponse: Decodable {
    let ok: Bool
    let service: String?
}

struct ErrorResponse: Decodable {
    let ok: Bool
    let error: String?
}
