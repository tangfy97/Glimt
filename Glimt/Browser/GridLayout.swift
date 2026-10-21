import AppKit

/// The grid's spacing, from one scale (8 / 16 / 24) shared with the folder columns and the
/// bottom bar, so every left edge in the window lines up at `margin`.
enum GridMetrics {
    static let margin: CGFloat = 16
    static let columnGap: CGFloat = 16
    /// Between a name and the next row's pictures: three times the gap inside a tile, so each
    /// name clearly belongs to the picture above it.
    static let rowGap: CGFloat = 24
    /// Pictures sit on a common baseline inside a 4:3 box; a 3:2 landscape fills its width.
    static let boxAspect: CGFloat = 0.75
    static let nameGap: CGFloat = 8
    static let nameHeight: CGFloat = 16
}

/// Uniform tile grid. Every frame is arithmetic on the index, so laying out a 10,000-item
/// folder costs the same as a 10-item one, and the tile size can change on every pinch
/// event without dropping frames.
final class GridLayout: NSCollectionViewLayout {
    var tileSide: CGFloat = 168 {
        didSet { if tileSide != oldValue { invalidateLayout() } }
    }
    var showsNames = true {
        didSet { if showsNames != oldValue { invalidateLayout() } }
    }

    private let columnGap = GridMetrics.columnGap
    private let rowGap = GridMetrics.rowGap
    private let insets = NSEdgeInsets(top: GridMetrics.margin, left: GridMetrics.margin, bottom: GridMetrics.rowGap, right: GridMetrics.margin)

    private(set) var columns = 1
    private(set) var cellWidth: CGFloat = 168
    private var count = 0
    private var width: CGFloat = 0

    var labelHeight: CGFloat { showsNames ? GridMetrics.nameGap + GridMetrics.nameHeight : 0 }
    var cellHeight: CGFloat { (cellWidth * GridMetrics.boxAspect).rounded() + labelHeight }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        width = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
        computeColumns()
    }

    /// Recomputes geometry immediately (used while pinching, before the next layout pass).
    func computeColumns() {
        let available = max(width - insets.left - insets.right, tileSide)
        columns = max(1, Int((available + columnGap) / (tileSide + columnGap)))
        cellWidth = floor((available - CGFloat(columns - 1) * columnGap) / CGFloat(columns))
    }

    override var collectionViewContentSize: NSSize {
        let rows = (count + columns - 1) / columns
        let height = insets.top + insets.bottom + CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * rowGap
        let visibleHeight = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0
        return NSSize(width: width, height: max(height, visibleHeight))
    }

    func frame(at index: Int) -> NSRect {
        let row = index / columns, column = index % columns
        return NSRect(x: insets.left + CGFloat(column) * (cellWidth + columnGap),
                      y: insets.top + CGFloat(row) * (cellHeight + rowGap),
                      width: cellWidth, height: cellHeight)
    }

    /// The index whose cell is under (or nearest to) `point`, in collection view coordinates.
    func index(nearest point: NSPoint) -> Int? {
        guard count > 0 else { return nil }
        let row = max(0, Int((point.y - insets.top) / (cellHeight + rowGap)))
        let column = min(columns - 1, max(0, Int((point.x - insets.left) / (cellWidth + columnGap))))
        return min(count - 1, row * columns + column)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0 else { return [] }
        let stride = cellHeight + rowGap
        let firstRow = max(0, Int((rect.minY - insets.top) / stride))
        let lastRow = max(firstRow, Int((rect.maxY - insets.top) / stride))
        let first = firstRow * columns
        let last = min(count, (lastRow + 1) * columns)
        guard first < last else { return [] }
        return (first..<last).map { attributes(at: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < count else { return nil }
        return attributes(at: indexPath.item)
    }

    private func attributes(at index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frame(at: index)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != width
    }
}
