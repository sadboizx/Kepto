import SwiftUI

/// Shared grid pieces ported from Photos' `PhotoGrid.swift`:
/// `DayHeader`, `SelectBottomBar`, `ZoomSegmentBar`.
///
/// Photos' `PhotoGrid` itself is NOT ported — it splits rows by hand;
/// Kepto keeps its `LazyVGrid` (see the plan, row 12).
/// `LibraryZoom` (which `ZoomSegmentBar` needs) lives in
/// `Models/LibraryModels.swift` since step 3 — it was here in step 2
/// only because the ported Library tab had not landed yet.

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

/// Segmented Years / Months / Days / All Photos picker above the
/// Library grid. Photos' `ZoomSegmentBar`, unchanged.
struct ZoomSegmentBar: View {
    @Binding var zoom: LibraryZoom

    var body: some View {
        Picker(L10n.library, selection: $zoom) {
            ForEach(LibraryZoom.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
