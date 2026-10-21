import AppKit

/// Uniform square-tile grid. Every frame is arithmetic on the index, so laying out a
/// 10,000-item folder costs the same as a 10-item one, and the tile size can change on
/// every pinch event without dropping frames.
final class GridLayout: NSCollectionViewLayout {
    var tileSide: CGFloat = 168 {
        didSet { if tileSide != oldValue { invalidateLayout() } }
    }
    var showsNames = true {
        didSet { if showsNames != oldValue { invalidateLayout() } }
    }

    let spacing: CGFloat = 12
    let insets = NSEdgeInsets(top: 16, left: 18, bottom: 22, right: 18)

    private(set) var columns = 1
    private(set) var cellWidth: CGFloat = 168
    private var count = 0
    private var width: CGFloat = 0

    var labelHeight: CGFloat { showsNames ? 22 : 0 }
    var cellHeight: CGFloat { cellWidth + labelHeight }

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
        columns = max(1, Int((available + spacing) / (tileSide + spacing)))
        cellWidth = floor((available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    override var collectionViewContentSize: NSSize {
        let rows = (count + columns - 1) / columns
        let height = insets.top + insets.bottom + CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * spacing
        let visibleHeight = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0
        return NSSize(width: width, height: max(height, visibleHeight))
    }

    func frame(at index: Int) -> NSRect {
        let row = index / columns, column = index % columns
        return NSRect(x: insets.left + CGFloat(column) * (cellWidth + spacing),
                      y: insets.top + CGFloat(row) * (cellHeight + spacing),
                      width: cellWidth, height: cellHeight)
    }

    /// The index whose cell is under (or nearest to) `point`, in collection view coordinates.
    func index(nearest point: NSPoint) -> Int? {
        guard count > 0 else { return nil }
        let row = max(0, Int((point.y - insets.top) / (cellHeight + spacing)))
        let column = min(columns - 1, max(0, Int((point.x - insets.left) / (cellWidth + spacing))))
        return min(count - 1, row * columns + column)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0 else { return [] }
        let stride = cellHeight + spacing
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
