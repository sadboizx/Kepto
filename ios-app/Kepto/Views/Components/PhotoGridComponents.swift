import SwiftUI

/// Shared grid pieces ported from Photos' `PhotoGrid.swift`:
/// `DayHeader`, `SelectBottomBar`, `ZoomSegmentBar`.
///
/// Photos' `PhotoGrid` itself is NOT ported — it splits rows by hand;
/// Kepto keeps its `LazyVGrid` (see the plan, row 12).
/// `LibraryZoom` (which `ZoomSegmentBar` needs) lives in
/// `Models/LibraryModels.swift` since step 3 — it was here in step 2
/// only because the ported Library tab had not landed yet.

/// Live cache of grid-cell global frames, for the viewer's
/// shrink-to-thumbnail dismiss: when the viewer opens from a cell,
/// the opener reads that cell's frame from here and hands it to the
/// viewer, which shrinks the media onto it on a dismissing release.
/// A plain class, NOT @State: the preference below fires on every
/// scroll frame (every visible cell's frame changes as it scrolls),
/// and those writes must not re-render the grid — the viewer only
/// reads the tapped cell's frame at tap time. Stale entries (cells
/// scrolled away or deleted) are harmless: they are never read.
final class CellFrameCache {
    var frames: [String: CGRect] = [:]
}

/// One preference per grid cell: its id + its frame in global
/// (screen) coordinates. The grid merges them into the
/// `CellFrameCache` above via `.onPreferenceChange`. The viewer's
/// page is full-screen, so a global frame is directly comparable
/// with the media's on-screen position.
struct CellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Day section header: large date title + optional subtitle, on a
/// bar background. Photos' `DayHeader`, unchanged.
struct DayHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(.bar)
    }
}

/// Bottom action bar shown in multi-select mode: Share / Favorite /
/// Add / Delete plus an extra `more` slot. Photos' `SelectBottomBar`,
/// unchanged except the labels are English inline strings for now —
/// Labels come from L10n (step 9).
struct SelectBottomBar<More: View>: View {
    var enabled: Bool
    var onShare: () -> Void
    var onFavorite: () -> Void
    var onAdd: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var more: () -> More

    var body: some View {
        HStack(spacing: 0) {
            barButton(L10n.share, "square.and.arrow.up", action: onShare)
            barButton(L10n.favorite, "heart", action: onFavorite)
            barButton(L10n.add, "rectangle.stack.badge.plus", action: onAdd)
            barButton(L10n.delete, "trash", action: onDelete)
            more()
                .frame(maxWidth: .infinity)
                .disabled(!enabled)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.bar)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

/// Years / Months / Days / All Photos pill floating over the bottom
/// of the Library grid (v60 style, restored): a dark frosted capsule
/// with the selected segment lighter, like Photos' control at the
/// bottom of the Library. NOT a segmented Picker in a safe-area inset
/// (that rendered as a wide bar, not a floating pill). The Library
/// places it in an `.overlay(alignment: .bottom)`; the grid's last row
/// clears it via a bottom content margin on the scroll view.
struct ZoomSegmentBar: View {
    @Binding var zoom: LibraryZoom

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LibraryZoom.allCases) { mode in
                let selected = zoom == mode
                Button {
                    zoom = mode
                } label: {
                    Text(mode.title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        // Photos: selected is white, unselected is a
                        // medium gray.
                        .foregroundStyle(selected ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selected ? Color.white.opacity(0.25) : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        // Photos-style frosted pill — regularMaterial (darker and
        // more opaque than ultraThinMaterial, so the pill has a real
        // visible background over the grid, like the real Photos app).
        .background(.regularMaterial, in: Capsule())
    }
}
