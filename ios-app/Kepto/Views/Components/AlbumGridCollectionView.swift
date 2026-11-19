import SwiftUI
import UIKit

/// Lưới UICollectionView cho các Album (Recents, Favorites, My Collection...).
/// Kế thừa kiến trúc từ PhotoGridCollectionView nhưng dùng cell PhotosGridCell
/// (hỗ trợ context menu, drag-select vuốt tự do) và có Footer load-more.
struct AlbumGridCollectionView: UIViewRepresentable {
    let items: [Item]
    let selecting: Bool
    let selectedIDs: Set<String>
    let cellWidth: CGFloat
    let spacing: CGFloat
    let columnCount: Int
    let topInset: CGFloat
    let hasMore: Bool
    let isLoadingMore: Bool

    let frameCache: CellFrameCache
    let scrollController: GridScrollController
    let viewModel: LibraryViewModel

    let contextMenuFor: (Item) -> AnyView
    let onTap: (Item) -> Void
    let onLoadMore: () -> Void
    let onDragSelect: (Set<String>) -> Void
    let onLastCellVisibilityChange: (Bool) -> Void
    let onRefresh: () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let cv = NoAnimationCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        cv.backgroundColor = .systemBackground
        cv.allowsSelection = false
        cv.delegate = context.coordinator
        cv.register(AlbumGridCell.self, forCellWithReuseIdentifier: AlbumGridCell.reuseID)
        cv.register(AlbumFooterCell.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: AlbumFooterCell.reuseID)

        // Pull-to-refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        cv.refreshControl = refreshControl

        context.coordinator.collectionView = cv
        context.coordinator.dataSource = makeDataSource(cv: cv, coordinator: context.coordinator)
        context.coordinator.lastCellWidth = cellWidth
        context.coordinator.lastColumnCount = columnCount
        scrollController.collectionView = cv

        cv.contentInset.top = topInset

        // Drag-to-select (vuốt tự do)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        cv.addGestureRecognizer(pan)
        context.coordinator.panRecognizer = pan

        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.parent = self

        if cv.contentInset.top != topInset {
            cv.contentInset.top = topInset
        }

        if context.coordinator.lastCellWidth != cellWidth || context.coordinator.lastColumnCount != columnCount {
            cv.setCollectionViewLayout(makeLayout(), animated: false)
            context.coordinator.lastCellWidth = cellWidth
            context.coordinator.lastColumnCount = columnCount
            frameCache.reset()
        }

        context.coordinator.applySnapshotIfChanged()

        if selecting != context.coordinator.lastSelecting {
            context.coordinator.reconfigureAllVisibleCells()
            context.coordinator.lastSelecting = selecting
        } else if selectedIDs != context.coordinator.lastSelectedIDs {
            let changed = selectedIDs.symmetricDifference(context.coordinator.lastSelectedIDs)
            context.coordinator.reconfigureVisibleCells(forChangedSelection: changed)
            context.coordinator.lastSelectedIDs = selectedIDs
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(cellWidth),
            heightDimension: .absolute(cellWidth)))

        // Dùng Array(repeating: count:) để ép đúng số cột
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(cellWidth)),
            subitems: Array(repeating: item, count: columnCount))
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing

        let footerSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(60))
        let footer = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: footerSize,
            elementKind: UICollectionView.elementKindSectionFooter,
            alignment: .bottom)
        section.boundarySupplementaryItems = [footer]

        // Bottom inset 64 cho thanh zoom pill
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 64, trailing: 0)

        return UICollectionViewCompositionalLayout(section: section)
    }

    private func makeDataSource(cv: UICollectionView, coordinator: Coordinator) -> UICollectionViewDiffableDataSource<Int, String> {
        let ds = UICollectionViewDiffableDataSource<Int, String>(collectionView: cv) { [weak coordinator] cv, indexPath, id in
            guard let coordinator,
                  let cell = cv.dequeueReusableCell(withReuseIdentifier: AlbumGridCell.reuseID, for: indexPath) as? AlbumGridCell
            else { return UICollectionViewCell() }
            coordinator.configure(cell: cell, id: id)
            return cell
        }
        ds.supplementaryViewProvider = { [weak coordinator] cv, kind, indexPath in
            guard let coordinator,
                  kind == UICollectionView.elementKindSectionFooter,
                  let footer = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: AlbumFooterCell.reuseID, for: indexPath) as? AlbumFooterCell else { return nil }
            coordinator.configure(footer: footer)
            return footer
        }
        return ds
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: AlbumGridCollectionView
        weak var collectionView: UICollectionView?
        var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        var panRecognizer: UIPanGestureRecognizer?
        var lastCellWidth: CGFloat?
        var lastColumnCount: Int?
        var lastSnapshotIDs: [String] = []
        var lastSelecting: Bool = false
        var lastSelectedIDs: Set<String> = []
        private var dragSelect = DragSelectTracker()
        private var didInitialScroll = false

        init(_ parent: AlbumGridCollectionView) {
            self.parent = parent
            self.lastSelecting = parent.selecting
            self.lastSelectedIDs = parent.selectedIDs
        }

        func applySnapshotIfChanged() {
            guard let ds = dataSource else { return }
            let newIDs = parent.items.map(\.id)
            if lastSnapshotIDs == newIDs { return }
            lastSnapshotIDs = newIDs
            var snap = NSDiffableDataSourceSnapshot<Int, String>()
            snap.appendSections([0])
            snap.appendItems(newIDs, toSection: 0)
            ds.apply(snap, animatingDifferences: false) { [weak self] in
                self?.performInitialScrollIfNeeded()
            }
        }

        private func performInitialScrollIfNeeded() {
            guard !didInitialScroll, let cv = collectionView, let ds = dataSource, ds.snapshot().numberOfItems > 0 else { return }
            didInitialScroll = true
            DispatchQueue.main.async {
                let n = ds.snapshot().numberOfItems
                guard n > 0 else { return }
                cv.scrollToItem(at: IndexPath(item: n - 1, section: 0), at: .bottom, animated: false)
            }
        }

        func configure(cell: AlbumGridCell, id: String) {
            guard let item = parent.items.first(where: { $0.id == id }) else { return }
            cell.configure(
                item: item,
                selecting: parent.selecting,
                selected: parent.selectedIDs.contains(id),
                frameCache: parent.frameCache,
                viewModel: parent.viewModel,
                onTap: { [weak self] in self?.parent.onTap(item) },
                contextMenu: parent.contextMenuFor(item)
            )
        }

        func configure(footer: AlbumFooterCell) {
            footer.configure(hasMore: parent.hasMore, isLoading: parent.isLoadingMore, onTap: { [weak self] in
                self?.parent.onLoadMore()
            })
        }

        func reconfigureAllVisibleCells() {
            guard let cv = collectionView else { return }
            for cell in cv.visibleCells {
                guard let gridCell = cell as? AlbumGridCell, let id = gridCell.id else { continue }
                configure(cell: gridCell, id: id)
            }
        }

        func reconfigureVisibleCells(forChangedSelection changed: Set<String>) {
            guard !changed.isEmpty, let cv = collectionView else { return }
            for cell in cv.visibleCells {
                guard let gridCell = cell as? AlbumGridCell, let id = gridCell.id, changed.contains(id) else { continue }
                configure(cell: gridCell, id: id)
            }
        }

        func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // Frame do PhotosGridCell tự ghi qua GeometryReader bên trong.
            // Ở đây chỉ cần xử lý load-more và isAtBottom.
            if indexPath.item == 0 {
                parent.onLoadMore()
            }
            if indexPath.item == parent.items.count - 1 {
                parent.onLastCellVisibilityChange(true)
            }
        }

        func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            if indexPath.item == parent.items.count - 1 {
                parent.onLastCellVisibilityChange(false)
            }
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            Task {
                await parent.onRefresh()
                sender.endRefreshing()
            }
        }

        // Drag select vuốt tự do (cũ)
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard parent.selecting, collectionView != nil else { return }
            let location = gesture.location(in: nil)
            switch gesture.state {
            case .began:
                dragSelect.reset()
                applyDrag(at: location, start: location)
            case .changed:
                applyDrag(at: location, start: location)
            default:
                dragSelect.reset()
            }
        }

        private func applyDrag(at current: CGPoint, start: CGPoint) {
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

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            parent.selecting && g === panRecognizer
        }
    }
}

// MARK: - Cell
final class AlbumGridCell: UICollectionViewCell {
    static let reuseID = "AlbumGridCell"
    private(set) var id: String?
    private let hostingController = UIHostingController(rootView: AnyView(EmptyView()))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.directionalLayoutMargins = .zero
        contentView.layoutMargins = .zero
        contentView.insetsLayoutMarginsFromSafeArea = false
        contentView.clipsToBounds = true
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = true
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostingController.view.frame = contentView.bounds
        UIView.performWithoutAnimation {
            contentView.addSubview(hostingController.view)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        layer.removeAllAnimations()
        hostingController.view.layer.removeAllAnimations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        UIView.performWithoutAnimation {
            if contentView.frame != bounds { contentView.frame = bounds }
            if hostingController.view.frame != contentView.bounds { hostingController.view.frame = contentView.bounds }
        }
    }

    func configure(
        item: Item,
        selecting: Bool,
        selected: Bool,
        frameCache: CellFrameCache,
        viewModel: LibraryViewModel,
        onTap: @escaping () -> Void,
        contextMenu: AnyView
    ) {
        self.id = item.id
        // Truyền frameCache vào PhotosGridCell để nó tự ghi bằng GeometryReader
        let base = PhotosGridCell(
            item: item,
            isSelectionMode: selecting,
            isSelected: selected,
            onTap: onTap,
            frameCache: frameCache
        )
        .environmentObject(viewModel) // PhotosGridCell cần viewModel? Thực ra không cần nếu truyền frameCache.

        let content = selecting ? AnyView(base) : AnyView(base.contextMenu { contextMenu })

        UIView.performWithoutAnimation {
            hostingController.rootView = content
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()
        }
    }
}

// MARK: - Footer
final class AlbumFooterCell: UICollectionReusableView {
    static let reuseID = "AlbumFooterCell"
    private let hostingController = UIHostingController(rootView: AnyView(EmptyView()))

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = true
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostingController.view.frame = bounds
        addSubview(hostingController.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        UIView.performWithoutAnimation {
            hostingController.view.frame = bounds
        }
    }

    func configure(hasMore: Bool, isLoading: Bool, onTap: @escaping () -> Void) {
        let content: AnyView
        if hasMore {
            if isLoading {
                content = AnyView(ProgressView().padding(.vertical, 12))
            } else {
                content = AnyView(
                    HStack {
                        Spacer()
                        Button(L10n.loadMore, action: onTap)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                )
            }
        } else {
            content = AnyView(EmptyView())
        }
        UIView.performWithoutAnimation {
            hostingController.rootView = content
            hostingController.view.setNeedsLayout()
        }
    }
}
