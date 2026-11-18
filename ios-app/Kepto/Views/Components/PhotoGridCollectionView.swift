import SwiftUI
import UIKit

/// Handle for driving the All Photos UICollectionView from SwiftUI
/// (scroll to bottom on open / re-tap, scroll to a specific cell when
/// the viewer pages). Populated by `PhotoGridCollectionView` via a
/// weak reference; held as `@State` in LibraryView. Nil after the
/// view is torn down (zoom changed away from .all) — the next
/// `makeUIView` re-populates it.
@MainActor
final class GridScrollController {
    weak var collectionView: UICollectionView?

    var itemCount: Int {
        guard let ds = dataSourceSnapshot() else { return 0 }
        return ds.numberOfItems
    }

    func scrollToBottom(animated: Bool) {
        guard let cv = collectionView,
              let ds = cv.dataSource as? UICollectionViewDiffableDataSource<Int, String>
        else { return }
        let n = ds.snapshot().numberOfItems
        guard n > 0 else { return }
        cv.scrollToItem(at: IndexPath(item: n - 1, section: 0), at: .bottom, animated: animated)
    }

    func scrollTo(id: String, at position: UICollectionView.ScrollPosition, animated: Bool) {
        guard let cv = collectionView,
              let ds = cv.dataSource as? UICollectionViewDiffableDataSource<Int, String>,
              let indexPath = ds.indexPath(for: id)
        else { return }
        cv.scrollToItem(at: indexPath, at: position, animated: animated)
    }

    private func dataSourceSnapshot() -> NSDiffableDataSourceSnapshot<Int, String>? {
        guard let cv = collectionView,
              let ds = cv.dataSource as? UICollectionViewDiffableDataSource<Int, String>
        else { return nil }
        return ds.snapshot()
    }
}

/// All Photos grid on UICollectionView (Đợt 2, C1=a).
///
/// WHY migrate from LazyVGrid:
/// - `LazyVGrid` lays out every laid-out cell on any state change that
///   forces a layout pass; `UICollectionView` reuses cells, prefetches
///   them (`UICollectionViewDataSourcePrefetching`) and only lays out
///   what's in the viewport plus a small buffer.
/// - The `visibleWindow` (120-item cap) + `growWindowIfNeeded` hack
///   disappears — the collection view virtualizes 10k+ items natively.
/// - Scroll APIs are Apple Photos-exact: `scrollToItem(_:at: .bottom)`
///   on open / re-tap; scroll-to-current when the viewer pages.
/// - `defaultScrollAnchor(.bottom)` (a SwiftUI layout anchor) is
///   replaced by an explicit post-layout `scrollToItem` in the
///   Coordinator. Same UX (opens at newest), no SwiftUI-only path.
///
/// Design:
/// - Cells host `AssetThumbnail` (SwiftUI) via `UIHostingConfiguration`
///   (iOS 16+; target is 17.4). `.environmentObject(viewModel)` is
///   injected explicitly — the collection view's cell environment does
///   not inherit the SwiftUI env from the caller.
/// - `.id(source.id)` inside the hosted view forces a fresh `@State`
///   when a cell is reused for a different id — otherwise the reused
///   cell would briefly show the wrong thumbnail. Same-id reuses do
///   not restart `.task` (SwiftUI diffing) — no per-scroll re-fetches.
/// - Frame writer: `willDisplay` reads the cell's `layoutAttributes`
///   frame, converts to window coords (accounts for contentOffset),
///   and writes into `CellFrameCache`. Same interface as the old
///   GeometryReader writer — but the write is one-shot per display,
///   not a `.onChange(of: CGRect)` on every scroll frame.
/// - Tap: SwiftUI `.onTapGesture` inside the hosted cell. Selection
///   toggles via the same `handleTap` callback (parent's closure).
/// - Context menu: SwiftUI `.contextMenu` inside the hosted cell.
/// - Drag-to-select: a `UIPanGestureRecognizer` on the collection view,
///   gated on `selecting` and coexisting with the scroll (simultaneous
///   recognition). Fed into the existing `DragSelectTracker` — same
///   disambiguation logic (vertical-first → scroll, horizontal → select).
/// - `willDisplay` / `didEndDisplaying` on the last id also drive
///   `onLastCellVisibilityChange` so LibraryView can track `isAtBottom`
///   without `gridCell.onAppear` (which the collection view replaces).
/// - `willDisplay` also drives `onWillDisplayNearTop` so the paged
///   `items` preload (`maybeLoadMore`) keeps working for All Photos
///   (the old trigger was `gridCell.onAppear`, which the collection
///   view replaces).
struct PhotoGridCollectionView: UIViewRepresentable {
    let ids: [String]
    let selecting: Bool
    let selectedIDs: Set<String>
    /// Computed by the parent from the viewport width + size class:
    /// `.regular` → 8 cols, `.compact` → 4 cols, spacing 2pt.
    let cellWidth: CGFloat
    let spacing: CGFloat
    /// Top content inset (status bar + nav bar, measured by the
    /// parent): replicates the old ScrollView's
    /// `.contentMargins(.top, topChromeHeight)` — the collection
    /// view ignores the top safe area, so the inset is applied
    /// manually (see `makeUIView`).
    let topInset: CGFloat
    /// Column count — needed for the edge-row auto-select in
    /// `handlePan` (row = indexPath.item / columnCount).
    let columnCount: Int
    let frameCache: CellFrameCache
    let scrollController: GridScrollController
    let viewModel: LibraryViewModel
    let sourceFor: (String) -> (any GridItemSource)?
    /// Parent builds the cell's context menu here (already AnyView-wrapped).
    let contextMenuFor: (String) -> AnyView
    /// Tap callback: same `handleTap(id)` behavior as before (select
    /// toggle in select mode, open viewer otherwise).
    let onTap: (String) -> Void
    /// Prefetch callback: called with the ids about to be shown.
    /// LibraryViewModel's prefetch is delta-safe — cached ids skip.
    let onPrefetch: ([String]) -> Void
    /// Drag-to-select: parent's `selection` setter.
    let onDragSelect: (Set<String>) -> Void
    /// Called with the index of a cell about to be displayed near
    /// the oldest end (within 10 of the oldest loaded full `Item`):
    /// the parent pages the next `items` batch ahead (same trigger
    /// `gridCell.onAppear` used to fire via `maybeLoadMore`).
    let onWillDisplayNearTop: (Int) -> Void
    /// True when the newest cell enters the viewport, false when it
    /// leaves. Drives `isAtBottom` (needed by maybeScrollToNewItem).
    let onLastCellVisibilityChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: makeLayout(cellWidth: cellWidth, spacing: spacing))
        cv.backgroundColor = .systemBackground
        // Tap handled by the SwiftUI cell's .onTapGesture — the
        // collection view's own selection stays off so taps do not
        // fire didSelectItemAt in parallel.
        cv.allowsSelection = false
        // The view ignores the top safe area (SwiftUI side) and the
        // top inset is applied manually from `topInset` (same value
        // the old ScrollView used as its top content margin), so the
        // system must not add its own adjustment on top.
        cv.contentInsetAdjustmentBehavior = .never
        // Đợt 2 fix (theo diff DeepSeek): bottom 64 chuyển xuống
        // section.contentInsets (xem makeLayout) thay vì contentInset
        // — cell cuối vẫn cuộn clear khỏi zoom pill.
        cv.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        cv.scrollIndicatorInsets = cv.contentInset
        cv.prefetchDataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.register(GridCell.self, forCellWithReuseIdentifier: GridCell.reuseID)
        context.coordinator.collectionView = cv
        context.coordinator.dataSource = makeDataSource(cv: cv, coordinator: context.coordinator)
        context.coordinator.lastCellWidth = cellWidth
        context.coordinator.lastTopInset = topInset
        scrollController.collectionView = cv

        // Drag-to-select: simultaneous with the scroll (the tracker
        // disambiguates: vertical-first → scroll, horizontal → select).
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        cv.addGestureRecognizer(pan)
        context.coordinator.panRecognizer = pan

        // Pull-to-refresh: the SwiftUI `.refreshable` on the body has
        // no ScrollView under it in the .all branch, so the collection
        // view owns its own UIRefreshControl (same action).
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        cv.refreshControl = refreshControl

        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.parent = self

        // Relayout on cell-width change (size class / rotation).
        if let current = context.coordinator.lastCellWidth, current != cellWidth {
            cv.setCollectionViewLayout(makeLayout(cellWidth: cellWidth, spacing: spacing), animated: false)
            context.coordinator.lastCellWidth = cellWidth
            // After a relayout, all cell frames are stale.
            frameCache.reset()
        }

        // Top inset change (topChromeHeight latches to its max as
        // the chrome is measured): keep content + indicator insets
        // in sync with the parent.
        if context.coordinator.lastTopInset != topInset {
            cv.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            cv.scrollIndicatorInsets = cv.contentInset
            context.coordinator.lastTopInset = topInset
        }

        // Data source: apply only when ids changed (skip no-op applies
        // that would reset the visible cells unnecessarily).
        context.coordinator.applySnapshotIfChanged()

        // Reconfigure visible cells whose state changed. Selection
        // changes → reconfigure only the symmetric difference; the
        // `selecting` flag change → reconfigure every visible cell
        // (checkmarks show/hide for all). The selecting branch also
        // refreshes lastSelectedIDs so a simultaneous selecting +
        // selection change does not skip the selection diff.
        if selecting != context.coordinator.lastSelecting {
            context.coordinator.reconfigureAllVisibleCells()
            context.coordinator.lastSelecting = selecting
            context.coordinator.lastSelectedIDs = selectedIDs
        } else if selectedIDs != context.coordinator.lastSelectedIDs {
            let changed = selectedIDs.symmetricDifference(context.coordinator.lastSelectedIDs)
            context.coordinator.reconfigureVisibleCells(forChangedSelection: changed)
            context.coordinator.lastSelectedIDs = selectedIDs
        }
    }

    private func makeLayout(cellWidth: CGFloat, spacing: CGFloat) -> UICollectionViewLayout {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(cellWidth),
            heightDimension: .absolute(cellWidth)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(cellWidth)),
            subitems: [item])
        group.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 64, trailing: 0)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func makeDataSource(cv: UICollectionView, coordinator: Coordinator)
        -> UICollectionViewDiffableDataSource<Int, String> {
        UICollectionViewDiffableDataSource<Int, String>(collectionView: cv) { [weak coordinator] cv, indexPath, id in
            guard let coordinator,
                  let cell = cv.dequeueReusableCell(withReuseIdentifier: GridCell.reuseID, for: indexPath) as? GridCell
            else { return UICollectionViewCell() }
            coordinator.configure(cell: cell, id: id)
            return cell
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
        var parent: PhotoGridCollectionView
        weak var collectionView: UICollectionView?
        var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        var panRecognizer: UIPanGestureRecognizer?
        var lastCellWidth: CGFloat?
        var lastTopInset: CGFloat?
        var lastSnapshotIDs: [String] = []
        var lastSelecting: Bool = false
        var lastSelectedIDs: Set<String> = []
        private var dragSelect = DragSelectTracker()
        private var didInitialScroll = false

        init(_ parent: PhotoGridCollectionView) {
            self.parent = parent
            self.lastSelecting = parent.selecting
            self.lastSelectedIDs = parent.selectedIDs
        }

        // MARK: Snapshot

        func applySnapshotIfChanged() {
            guard let ds = dataSource else { return }
            if lastSnapshotIDs == parent.ids { return }
            lastSnapshotIDs = parent.ids
            var snap = NSDiffableDataSourceSnapshot<Int, String>()
            snap.appendSections([0])
            snap.appendItems(parent.ids, toSection: 0)
            ds.apply(snap, animatingDifferences: false) { [weak self] in
                self?.performInitialScrollIfNeeded()
            }
        }

        /// First non-empty layout: pin to the bottom (newest). Same UX
        /// as the LazyVGrid's `.defaultScrollAnchor(.bottom)` — but the
        /// collection view has no such anchor, so we do it explicitly
        /// after the data-source apply completes (content size is
        /// valid at that point). Runs once per Coordinator lifetime.
        private func performInitialScrollIfNeeded() {
            guard !didInitialScroll,
                  let cv = collectionView,
                  let ds = dataSource,
                  ds.snapshot().numberOfItems > 0
            else { return }
            didInitialScroll = true
            // One runloop hop so layout is settled (scrollToItem is a
            // no-op when the target's layout attributes do not exist).
            DispatchQueue.main.async {
                let n = ds.snapshot().numberOfItems
                guard n > 0 else { return }
                cv.scrollToItem(at: IndexPath(item: n - 1, section: 0), at: .bottom, animated: false)
            }
        }

        // MARK: Cell configuration

        func configure(cell: GridCell, id: String) {
            cell.configure(
                id: id,
                source: parent.sourceFor(id),
                selecting: parent.selecting,
                selected: parent.selectedIDs.contains(id),
                viewModel: parent.viewModel,
                onTap: { [weak self] in self?.parent.onTap(id) },
                contextMenu: parent.contextMenuFor(id)
            )
        }

        func reconfigureAllVisibleCells() {
            guard let cv = collectionView else { return }
            for cell in cv.visibleCells {
                guard let gridCell = cell as? GridCell, let id = gridCell.id else { continue }
                configure(cell: gridCell, id: id)
            }
        }

        func reconfigureVisibleCells(forChangedSelection changed: Set<String>) {
            guard !changed.isEmpty, let cv = collectionView else { return }
            for cell in cv.visibleCells {
                guard let gridCell = cell as? GridCell,
                      let id = gridCell.id,
                      changed.contains(id)
                else { continue }
                configure(cell: gridCell, id: id)
            }
        }

        // MARK: UICollectionViewDelegate

        func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard let gridCell = cell as? GridCell,
                  let id = gridCell.id,
                  let attrs = cv.layoutAttributesForItem(at: indexPath)
            else { return }
            // Cell frame in window coords — same shape the old
            // GeometryReader wrote (geo.frame(in: .global)). Converting
            // from the collection view's content coordinate space to
            // nil (window) accounts for the current contentOffset, so
            // a scrolled cell gets a negative y exactly like before.
            let frameInWindow = cv.convert(attrs.frame, to: nil)
            parent.frameCache.set(id, frameInWindow)

            // Paged `items` preload: the old trigger was
            // gridCell.onAppear → maybeLoadMore, which never runs for
            // the collection view. Fire the parent's callback when a
            // cell appears near the oldest loaded boundary (same
            // guard as maybeLoadMore itself).
            if parent.viewModel.hasMore,
               indexPath.item <= parent.viewModel.cachedOldestLoadedIndex + 10 {
                parent.onWillDisplayNearTop(indexPath.item)
            }

            // isAtBottom tracking for maybeScrollToNewItem.
            if indexPath.item == parent.ids.count - 1 {
                parent.onLastCellVisibilityChange(true)
            }
        }

        func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            if indexPath.item == parent.ids.count - 1 {
                parent.onLastCellVisibilityChange(false)
            }
        }

        // MARK: Prefetch

        func collectionView(_ cv: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let prefetchIDs: [String] = indexPaths.compactMap { idx in
                idx.item < parent.ids.count ? parent.ids[idx.item] : nil
            }
            if !prefetchIDs.isEmpty { parent.onPrefetch(prefetchIDs) }
        }

        // MARK: Drag-to-select

        /// Edge-row auto-select (Apple Photos): a drag that starts
        /// on a first/last-column cell selects/deselects whole rows
        /// as the finger moves vertically. Row is derived from
        /// `indexPathForItem` (row = item / columnCount) so content
        /// offset and insets are accounted for — never from raw y.
        private var rowSelectMode: Bool = false
        private var rowSelectInitialSelection: Bool = true
        private var lastRowSelectRow: Int = -1

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard parent.selecting, let cv = collectionView else { return }
            let location = gesture.location(in: nil) // window coords = global
            switch gesture.state {
            case .began:
                dragSelect.reset()
                rowSelectMode = false
                lastRowSelectRow = -1
                // Row-select only when the drag starts on an edge
                // column (first or last). Otherwise the regular
                // DragSelectTracker path handles it.
                let locInCV = gesture.location(in: cv)
                if let indexPath = cv.indexPathForItem(at: locInCV) {
                    let col = indexPath.item % parent.columnCount
                    if col == 0 || col == parent.columnCount - 1 {
                        rowSelectMode = true
                        let firstID = parent.ids[indexPath.item]
                        rowSelectInitialSelection = !parent.selectedIDs.contains(firstID)
                        applyRowSelect(at: indexPath.item)
                    }
                }
                if !rowSelectMode {
                    applyDrag(at: location, start: location)
                }
            case .changed:
                if rowSelectMode {
                    let locInCV = gesture.location(in: cv)
                    if let indexPath = cv.indexPathForItem(at: locInCV) {
                        applyRowSelect(at: indexPath.item)
                    }
                } else {
                    applyDrag(at: location, start: location)
                }
            default:
                dragSelect.reset()
                rowSelectMode = false
            }
        }

        /// Select/deselect every cell in the row containing `item`:
        /// the row's select state follows the first cell hit at drag
        /// start (selected → deselect the row, unselected → select
        /// it). Re-selecting the same row is a no-op.
        private func applyRowSelect(at item: Int) {
            guard parent.columnCount > 0, item < parent.ids.count else { return }
            let row = item / parent.columnCount
            guard row != lastRowSelectRow else { return }
            lastRowSelectRow = row
            var updated = parent.selectedIDs
            for col in 0..<parent.columnCount {
                let idx = row * parent.columnCount + col
                guard idx < parent.ids.count else { break }
                if rowSelectInitialSelection { updated.insert(parent.ids[idx]) } else { updated.remove(parent.ids[idx]) }
            }
            if updated != parent.selectedIDs {
                parent.onDragSelect(updated)
            }
        }

        private func applyDrag(at current: CGPoint, start: CGPoint) {
            // DragSelectTracker expects ScrollView-local start/current,
            // but with a direct pan we can pass global directly —
            // the tracker's `toGlobal` closure then becomes identity.
            // The tracker's disambiguation (vertical-first → scroll,
            // horizontal → select, first-cell-hit pins the mode) is
            // unchanged and still gates the collection view's own
            // scroll from being hijacked.
            let updated = dragSelect.update(
                start: start,
                current: current,
                toGlobal: { $0 },
                frames: parent.frameCache.frames,
                selection: parent.selectedIDs
            )
            if updated != parent.selectedIDs {
                parent.onDragSelect(updated)
            }
        }

        // MARK: Pull-to-refresh

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            Task {
                await parent.viewModel.fetch()
                await MainActor.run { sender.endRefreshing() }
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Let the select pan run alongside the collection view's
            // own scroll pan. The tracker never inserts unless the
            // first cell is hit horizontally — a plain vertical swipe
            // is a scroll and the tracker no-ops.
            true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            // The pan is inert outside select mode — the collection
            // view's scroll is the only vertical gesture then.
            parent.selecting && g === panRecognizer
        }
    }
}

// MARK: - Hosted cell

/// UICollectionViewCell that hosts a SwiftUI `AssetThumbnail` via
/// `UIHostingConfiguration` (iOS 16+). Reuse is handled by SwiftUI
/// diffing on `.id(source.id)` — a different id tears down and rebuilds
/// the hosted tree (fresh @State, no stale-thumbnail flash); the same
/// id short-circuits (no re-eval, no `.task` restart).
final class GridCell: UICollectionViewCell {
    static let reuseID = "GridCell"
    private(set) var id: String?

    func configure(
        id: String,
        source: (any GridItemSource)?,
        selecting: Bool,
        selected: Bool,
        viewModel: LibraryViewModel,
        onTap: @escaping () -> Void,
        contextMenu: AnyView
    ) {
        self.id = id
        let content: AnyView
        if let source {
            content = AnyView(
                AssetThumbnail(source: source, selecting: selecting, selected: selected)
                    .environmentObject(viewModel)
                    .id(source.id)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .contextMenu { contextMenu }
            )
        } else {
            content = AnyView(
                Color(uiColor: .secondarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
            )
        }
        // Đợt 2 fix (thử): UIHostingConfiguration mặc định inset
        // content theo layoutMargins của cell — thumbnail bị nhỏ
        // lại + lề so với LazyVGrid trước đây. Ép margins về 0 để
        // thumbnail tràn đúng cell như Apple Photos. Nếu không phải
        // nguyên nhân thì đây là no-op, sẽ loại trừ hướng này.
        contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0)
    }
}
