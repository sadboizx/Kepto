import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

/// Bottom action bar shown in multi-select mode, Photos' Recents
/// select bar: Share icon — center count text — Delete icon — "…"
/// menu. Icon-only; blue while anything is selected, gray while
/// nothing is (the buttons are disabled then). Favorite / Add to
/// Album live in the `more` menu, not on the bar. The counts come
/// from the caller — the wording ("1 Photo Selected" / "N Items
/// Selected" / "Select Items") is `L10n.selectionSummary`.
struct SelectBottomBar<More: View>: View {
    var photoCount: Int
    var videoCount: Int
    var unknownCount: Int
    var onShare: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var more: () -> More

    private var total: Int { photoCount + videoCount + unknownCount }

    var body: some View {
        HStack(spacing: 0) {
            iconButton("square.and.arrow.up", action: onShare)
                .accessibilityLabel(L10n.share)
            Text(L10n.selectionSummary(photos: photoCount, videos: videoCount, unknown: unknownCount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
            iconButton("trash", action: onDelete)
                .accessibilityLabel(L10n.delete)
            more()
                .frame(width: 44, height: 44)
                .foregroundStyle(total > 0 ? Color.blue : Color.gray)
                .disabled(total == 0)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .foregroundStyle(total > 0 ? Color.blue : Color.gray)
        }
        .disabled(total == 0)
        .buttonStyle(.plain)
    }
}

/// Drag-to-select (Photos): in select mode, dragging a finger
/// across cells selects/deselects them in bulk. One tracker serves
/// both grids (Library + Album) — both keep the same
/// `CellFrameCache` of global cell frames, and both ScrollViews
/// report their global viewport, so a ScrollView-local drag point
/// converts to global by adding the viewport origin.
///
/// The mode is fixed by the FIRST cell hit: dragging from an
/// unselected cell selects everything touched, from a selected
/// cell deselects. A vertical-dominant drag is a scroll, not a
/// select — until a cell has been hit, segments with |dy| > 2*|dx|
/// are ignored, so a plain swipe still scrolls; once selection
/// has begun, the drag keeps applying even if it turns vertical.
/// Points are sampled along each segment (~20pt steps) so a fast
/// drag cannot jump over a cell between two reported locations.
struct DragSelectTracker {
    /// true = this drag selects, false = it deselects; nil until
    /// the first cell is hit.
    private(set) var mode: Bool? = nil
    private var lastLocation: CGPoint? = nil

    mutating func reset() {
        mode = nil
        lastLocation = nil
    }

    /// Feed one drag update (`start`/`current` are ScrollView-local,
    /// as `DragGesture` reports them). `toGlobal` converts a local
    /// point to the global space the frame cache lives in. Returns
    /// the updated selection.
    mutating func update(start: CGPoint, current: CGPoint, toGlobal: (CGPoint) -> CGPoint, frames: [String: CGRect], selection: Set<String>) -> Set<String> {
        var selection = selection
        // First sample measures from the gesture's start point, so
        // a straight vertical swipe (a scroll) never hits a cell.
        let previous = lastLocation ?? start
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        defer { lastLocation = current }
        // Vertical-dominant and nothing hit yet: a scroll — keep
        // sampling, don't hit-test.
        if mode == nil && abs(dy) > 2 * abs(dx) { return selection }
        // Sample along the segment so a fast drag can't skip a cell.
        let distance = hypot(dx, dy)
        let steps = max(1, Int(ceil(distance / 20)))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            hitTest(toGlobal(CGPoint(x: previous.x + dx * t, y: previous.y + dy * t)), frames: frames, selection: &selection)
        }
        return selection
    }

    private mutating func hitTest(_ global: CGPoint, frames: [String: CGRect], selection: inout Set<String>) {
        guard let id = frames.first(where: { $0.value.contains(global) })?.key else { return }
        if mode == nil { mode = !selection.contains(id) }
        if mode == true { selection.insert(id) } else { selection.remove(id) }
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
    /// Round-18: tapping the ALREADY-selected segment scrolls the grid
    /// to the bottom (newest) instead of switching mode. The Library
    /// passes its animated scroll here; nil = plain mode switch.
    var onRetap: ((LibraryZoom) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LibraryZoom.allCases) { mode in
                let selected = zoom == mode
                Button {
                    // Re-tap on the active segment = scroll to bottom
                    // (Apple Photos pattern); a different segment just
                    // switches mode — no scroll, no reload.
                    if zoom == mode { onRetap?(mode) } else { zoom = mode }
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

/// Files-app document picker for the "…" menu's "Choose Files"
/// action: picks image/video files from Files and hands their URLs
/// to the existing upload pipeline (same as PhotosPicker picks).
/// `asCopy: true` copies the picked files into the app's temp
/// directory, so the URLs stay readable without security-scoped
/// resource handling. Multi-select. The sheet itself is attached at
/// the app root (KeptoTabView), like the PhotosPicker.
struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.image, UTType.video], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// The "New Album..." card at the top of an Add to Album sheet
/// (Photos): a gray placeholder with the Add-to-Album icon
/// (rectangle.stack.badge.plus, same as the "Add to Album" action)
/// and the "New Album..." label below, same size as an album card.
/// Tapping it opens the New Album name alert. Shared by the
/// import picker (ImportAlbumPickerView) and the long-press
/// picker (AddToCollectionPickerView).
struct NewAlbumCardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.systemGray5)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(L10n.newAlbum + "...")
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// One album card in an Add to Album sheet: cover thumbnail + name +
/// count, laid out like the Photos See All grid (square cover,
/// name + count underneath, regular weight — not bold). Shared by
/// the import picker (ImportAlbumPickerView) and the long-press
/// picker (AddToCollectionPickerView).
struct PickerAlbumCardView: View {
    let collection: MyCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let coverItemId = collection.coverItemId {
                    AspectThumbnail(itemId: coverItemId)
                } else {
                    Color(.systemGray5)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(collection.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(collection.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // The tappable region is exactly this card's bounds: a tap
        // on the bottom edge must pick this album, not the one
        // below it.
        .contentShape(Rectangle())
    }
}
