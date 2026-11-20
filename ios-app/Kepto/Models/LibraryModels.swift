import Foundation
import SwiftUI

/// Zoom levels of the Library grid, in Photos order (zoomed out →
/// zoomed in). Moved here from `PhotoGridComponents.swift` (step 2)
/// — it lives with the other ported Library models now. Titles come
/// from L10n (step 9).
enum LibraryZoom: Int, CaseIterable, Identifiable {
    case years = 0
    case months
    case days
    case all

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .years: return L10n.years
        case .months: return L10n.months
        case .days: return L10n.days
        case .all: return L10n.allPhotos
        }
    }

    func zoomedIn() -> LibraryZoom {
        LibraryZoom(rawValue: rawValue + 1) ?? self
    }

    func zoomedOut() -> LibraryZoom {
        LibraryZoom(rawValue: rawValue - 1) ?? self
    }
}

/// Which kind of album a row is. Merged (step 4) from Photos' 10-case
/// enum and Kepto's 2-case enum (`recents`/`favorites` in the old
/// CollectionDetailView.swift) into ONE enum: the cases Kepto needs
/// are `recents` / `favorites` (built-in albums), `user` (user-created
/// collections), `people` (creators — Photos' People & Pets slot),
/// `media` (Media Types rows: Videos / Photos), `deleted` (the
/// Utilities row: Recently Deleted, note-only — Kepto has no trash).
/// Dropped Photos cases and why: `shared` (Kepto has no sharing by
/// design), `hidden` (Hide dropped, Q3), `imports` (no auto-Imports
/// album since v56 — re-added 2026-11-20 as `recentlyAdded`: a Utilities
/// smart album, every Library item, newest added at the bottom like Recents),
/// `utility` (no such case — the Utilities section is built from plain rows).
enum AlbumKind: String, Hashable {
    case recents, recentlyAdded, favorites, user, people, media, deleted

    var title: String {
        switch self {
        case .recents: return L10n.recents
        case .recentlyAdded: return L10n.recentlyAdded
        case .favorites: return L10n.favorites
        case .user: return L10n.myAlbums
        case .people: return L10n.creators
        case .media: return L10n.mediaTypes
        case .deleted: return L10n.recentlyDeleted
        }
    }
}

/// One album row (My Albums / Creators / Media Types / Utilities).
/// Ported from Photos — `collectionID` is the MyCollection id (kind
/// `.user`), the creator username (kind `.people`), or nil for
/// built-in albums and Media Types / Utilities rows. `symbol`/`tint`
/// are only the no-cover fallback (album tiles show the cover
/// thumbnail when one exists).
struct AlbumItem: Identifiable, Hashable {
    let id: String
    var title: String
    var count: Int
    var coverID: String?
    var kind: AlbumKind
    var symbol: String
    var tint: AlbumTint
    var collectionID: String?
}

/// One day in the Library grid: the date, its title/subtitle, and the
/// ids of its items (newest first). Ported from Photos — `assetIDs`
/// renamed to `itemIDs` (Kepto items are not PHAssets).
struct DaySection: Identifiable, Hashable {
    let id: String
    let date: Date
    var title: String
    var subtitle: String?
    var itemIDs: [String]
}

/// One month in the Library grid: the date, its title, its item ids,
/// and the newest item as the cover. Ported from Photos, same
/// `assetIDs` → `itemIDs` rename.
struct MonthSection: Identifiable, Hashable {
    let id: String
    let date: Date
    var title: String
    var itemIDs: [String]
    var coverID: String?
}

/// One year in the Library grid: the year, its title, its item ids,
/// and up to 4 ids for the mosaic cover. Ported from Photos, same
/// rename.
struct YearSection: Identifiable, Hashable {
    let year: Int
    var title: String
    var itemIDs: [String]
    var coverIDs: [String]
    var id: String { title }
}

enum AlbumTint: String, Hashable {
    case blue, pink, orange, teal, green, yellow, purple, red, mint, indigo, brown, cyan, gray

    var color: Color {
        switch self {
        case .blue: .blue
        case .pink: .pink
        case .orange: .orange
        case .teal: .teal
        case .green: .green
        case .yellow: .yellow
        case .purple: .purple
        case .red: .red
        case .mint: .mint
        case .indigo: .indigo
        case .brown: .brown
        case .cyan: .cyan
        case .gray: .gray
        }
    }
}

/// One Memory (For You, step 6): a month with enough items, its
/// title, and its item ids. Ported from Photos — no place (Kepto
/// items have no location), so the title is the month only.
struct MemoryItem: Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var itemIDs: [String]
    var coverID: String?
}

/// The detail viewer route (step 7): the ids to page through, the id
/// to start on, and the title. Ported from Photos — ids are Kepto
/// item ids, resolved against the ViewModel cache.
struct ViewerRoute: Identifiable {
    let id = UUID()
    let itemIDs: [String]
    let startID: String
    var title: String = L10n.library
}

/// Date labels ported from Photos' `DateLabels` — same formats,
/// "Today" / "Yesterday" from L10n (step 9).
enum DateLabels {
    static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.today }
        if calendar.isDateInYesterday(date) { return L10n.yesterday }
        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM y")
        }
        return formatter.string(from: date)
    }

    static func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return formatter.string(from: date)
    }

    static func shortMonth(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: date)
    }

    static func timeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func fullStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
