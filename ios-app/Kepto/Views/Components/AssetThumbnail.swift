import SwiftUI

/// The data a grid cell needs from an item, whether it comes from a
/// full `Item` (Library grid, paged) or light `ItemMetadata` (search
/// results, groupings). Photos' `AssetThumbnail` read the same fields
/// off `PHAsset`; this protocol is the Kepto equivalent — the cell
/// never sees a PHAsset.
protocol GridItemSource {
    var id: String { get }
    /// "0:52" for videos, nil for photos.
    var durationText: String? { get }
    /// TikTok-style view count ("20.2K"), shown when there is no
    /// duration. Nil for photos and for metadata (which has no count).
    var viewCountText: String? { get }
    var isFavorite: Bool { get }
    /// True while the ingest is still running (full `Item` only —
    /// metadata has no status, so it is never pending).
    var isPending: Bool { get }
    /// True when the ingest failed (full `Item` only).
    var isFailed: Bool { get }
    /// True for still images — they show no duration/view-count badge.
    var isPhoto: Bool { get }
}

extension GridItemSource {
    /// Duration first (Photos style); view count when the duration
    /// is unknown. Photos show no badge at all.
    var badgeText: String? {
        guard !isPhoto else { return nil }
        return durationText ?? viewCountText
    }
}

extension Item: GridItemSource {
    var durationText: String? { formattedDuration }
    var viewCountText: String? { formattedViewCount }
    var isPending: Bool { status == .pending }
    var isFailed: Bool { status == .failed }
    var isPhoto: Bool { contentType?.hasPrefix("image/") == true }
}

extension ItemMetadata: GridItemSource {
    var durationText: String? { formatDuration(duration) }
    var viewCountText: String? { nil }
    var isPending: Bool { false }
    var isFailed: Bool { false }
    var isPhoto: Bool { contentType?.hasPrefix("image/") == true }
}

/// "0:52" from a duration in seconds — same format as
/// `Item.formattedDuration`, shared so `ItemMetadata` does not
/// duplicate it.
private func formatDuration(_ duration: Double?) -> String? {
    guard let duration, duration > 0 else { return nil }
    let total = Int(duration.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Square grid cell: thumbnail + duration/view-count badge, favorite
/// heart, pending spinner, failed dot, selection checkmark. Photos'
/// `AssetThumbnail`, rewritten for Kepto `Item` / `ItemMetadata`
/// (via `GridItemSource`) and the `ThumbnailPipeline` — no PHAsset.
///
/// Badges kept from Kepto's `PhotosGridCell` (duration first, view
/// count fallback, favorite heart, pending spinner, failed dot);
/// Photos' Live/Portrait badges are dropped — `Item` has no such
/// flags. The selection checkmark sits top-trailing like Photos
/// (Kepto's old cell had it top-leading); the favorite heart is
/// hidden while selecting so the two never overlap.
///
/// The square is forced the Kepto way — a `Color` (no intrinsic
/// aspect) + `.aspectRatio` + `.overlay` + `.clipped()` +
/// `.contentShape` (see `AspectThumbnail` in LibraryView.swift: a
/// ZStack + `.aspectRatio` does NOT force the square once the image
/// loads).
struct AssetThumbnail: View {
    let source: any GridItemSource
    var selecting = false
    var selected = false
    var cornerRadius: CGFloat = 0
    /// Show the duration / view-count badge (bottom-leading). The
    /// Search results grid hides it (round 3 — no time on Search
    /// thumbnails); Library / For You keep it.
    var showBadge = true

    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var image: UIImage?

    var body: some View {
        Color(uiColor: .secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay { pendingOverlay }
            .overlay(alignment: .bottomLeading) { if showBadge { badgeRow } }
            .overlay(alignment: .topTrailing) { favoriteMark }
            .overlay(alignment: .topTrailing) { selectionMark }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: source.id) {
                guard let api = viewModel.api else { return }
                image = await ThumbnailPipeline.shared.thumbnail(id: source.id, api: api)
            }
    }

    @ViewBuilder
    private var pendingOverlay: some View {
        if source.isPending {
            ZStack {
                Color.black.opacity(0.35)
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if source.isFailed {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            } else if let badge = source.badgeText {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(5)
    }

    @ViewBuilder
    private var favoriteMark: some View {
        if source.isFavorite && !selecting {
            Image(systemName: "heart.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                .padding(6)
        }
    }

    @ViewBuilder
    private var selectionMark: some View {
        if selecting {
            ZStack {
                Circle()
                    .fill(selected ? Color.accentColor : Color.black.opacity(0.28))
                Circle()
                    .stroke(Color.white, lineWidth: 1.6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .padding(5)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }
}
