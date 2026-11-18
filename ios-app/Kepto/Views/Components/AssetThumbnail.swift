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
    /// Upload progress (0...1) of a LOCAL placeholder item while its
    /// file uploads from the device. Nil for every server item.
    var uploadProgress: Double? { get }
}

extension GridItemSource {
    /// Duration first (Photos style); view count when the duration
    /// is unknown. Photos show no badge at all.
    var badgeText: String? {
        guard !isPhoto else { return nil }
        return durationText ?? viewCountText
    }

    /// No upload in progress (server items never upload).
    var uploadProgress: Double? { nil }
}

/// Progress ring for a cell whose file is uploading from the device:
/// a white arc over a dimmed disc, top-right corner of the cell.
/// The cell itself is NOT dimmed — the file already exists on the
/// device, only the upload is in flight.
struct UploadProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.55))
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 26, height: 26)
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
/// flags. The selection checkmark sits bottom-trailing like Photos;
/// the duration badge is hidden while selecting (the checkmark owns
/// that corner then) and the favorite heart is hidden too, so the
/// two never overlap. Unselected cells dim slightly in select mode
/// so the selection stands out.
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
    /// Search Categories / People covers hide it (round 7 — no time
    /// on category or person covers); Search results, Library and
    /// For You keep it.
    var showBadge = true
    /// Show the white favorite heart at the bottom-left. Covers
    /// (month card, person avatar) hide it — the heart belongs on
    /// item thumbnails, and the month card's title sits at the
    /// bottom-left where the heart would land.
    var showFavoriteMark = true

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
            // In select mode unselected cells dim slightly (Photos);
            // the overlays below are added after, so the checkmark
            // and badges stay full-strength.
            .opacity(selecting && !selected ? 0.7 : 1)
            .overlay { pendingOverlay }
            .overlay(alignment: .bottomLeading) { if showBadge && !selecting { badgeRow } }
            .overlay(alignment: .bottomLeading) { favoriteMark }
            .overlay(alignment: .bottomTrailing) { selectionMark }
            .overlay(alignment: .topTrailing) { uploadRing }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: source.id) {
                guard let api = viewModel.api else { return }
                image = await ThumbnailPipeline.shared.thumbnail(id: source.id, api: api)
            }
    }

    @ViewBuilder
    private var pendingOverlay: some View {
        // An uploading placeholder is NOT dimmed — the file already
        // exists on the device, only the upload is in flight; the
        // progress ring (above) is its only affordance.
        if source.isPending && source.uploadProgress == nil {
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
        if showFavoriteMark && source.isFavorite && !selecting {
            Image(systemName: "heart.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                .padding(6)
        }
    }

    /// Upload progress ring (top-right). Hidden while selecting —
    /// the selection checkmark owns that corner then. Placeholders
    /// are never pending-dimmed (metadata has no status), so the
    /// ring is the only upload affordance on Library cells.
    @ViewBuilder
    private var uploadRing: some View {
        if let progress = source.uploadProgress, progress < 1, !selecting {
            UploadProgressRing(progress: progress)
                .padding(5)
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
                        .transition(.scale)
                }
            }
            .frame(width: 22, height: 22)
            .padding(5)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
        }
    }
}

extension AssetThumbnail: Equatable {
    /// Hot-path fix: when the parent's state changes (selection,
    /// metadata refresh, window growth), SwiftUI skips body
    /// evaluation for cells whose inputs did not change. Compares
    /// the `source` fields one by one — never the `source`
    /// existential itself — plus the cell's own props. If a new
    /// UI-affecting prop is added to this view or to
    /// `GridItemSource`, it MUST be added here or the cell goes
    /// stale.
    static func == (lhs: AssetThumbnail, rhs: AssetThumbnail) -> Bool {
        lhs.source.id == rhs.source.id
            && lhs.source.isFavorite == rhs.source.isFavorite
            && lhs.source.isPending == rhs.source.isPending
            && lhs.source.isFailed == rhs.source.isFailed
            && lhs.source.isPhoto == rhs.source.isPhoto
            && lhs.source.uploadProgress == rhs.source.uploadProgress
            && lhs.source.durationText == rhs.source.durationText
            && lhs.source.viewCountText == rhs.source.viewCountText
            && lhs.selecting == rhs.selecting
            && lhs.selected == rhs.selected
            && lhs.cornerRadius == rhs.cornerRadius
            && lhs.showBadge == rhs.showBadge
            && lhs.showFavoriteMark == rhs.showFavoriteMark
    }
}
