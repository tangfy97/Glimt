import AppKit

/// Lets the window controller see key events before the menus and the first responder.
final class MainWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyHandler?(event) == true || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Folder columns on top (under the toolbar), the grid below them, the viewer covering both
/// when open, and the sort bar along the bottom.
final class RootView: NSView {
    var browserView: NSView? { didSet { install(browserView, below: viewerView) } }
    var viewerView: NSView? { didSet { install(viewerView, below: emptyState) } }
    var emptyState: NSView? { didSet { install(emptyState, below: nil) } }
    var sortBar: NSView? { didSet { install(sortBar, below: nil) } }
    var folderColumns: NSView? { didSet { install(folderColumns, below: viewerView) } }
    var divider: FolderBrowserDivider? {
        didSet {
            install(divider, below: viewerView)
            divider?.onDrag = { [weak self] y in self?.dragDivider(toWindowY: y) }
            divider?.onDragEnded = { [weak self] in self?.onFolderColumnsChanged?() }
            divider?.onDoubleClick = { [weak self] in
                guard let self else { return }
                self.showsFolderColumns.toggle()
                self.onFolderColumnsChanged?()
            }
        }
    }
    var showsSortBar = true { didSet { needsLayout = true } }
    var showsFolderColumns = true { didSet { needsLayout = true } }
    var folderColumnsHeight: CGFloat = 170 { didSet { needsLayout = true } }
    /// The viewer covers everything, so the columns step aside while it is open.
    var isViewerMode = false { didSet { needsLayout = true } }
    /// The divider was dragged or double-clicked: persist `showsFolderColumns` and the height.
    var onFolderColumnsChanged: (() -> Void)?

    static let minimumColumnsHeight: CGFloat = 90

    private func install(_ view: NSView?, below other: NSView?) {
        guard let view else { return }
        if let other, other.superview === self {
            addSubview(view, positioned: .below, relativeTo: other)
        } else {
            addSubview(view)
        }
        needsLayout = true
    }

    private var contentRect: NSRect {
        let barHeight: CGFloat = showsSortBar ? SortBarView.height : 0
        return NSRect(x: 0, y: barHeight, width: bounds.width, height: bounds.height - barHeight)
    }

    /// Where the columns start: just below the toolbar (which overlaps the content view).
    private var columnsTop: CGFloat {
        let content = contentRect
        guard let window else { return content.maxY }
        let layoutTop = convert(window.contentLayoutRect, from: nil).maxY
        return min(content.maxY, layoutTop)
    }

    private var maximumColumnsHeight: CGFloat {
        max(Self.minimumColumnsHeight, (columnsTop - contentRect.minY) * 0.65)
    }

    private func dragDivider(toWindowY y: CGFloat) {
        let height = columnsTop - convert(NSPoint(x: 0, y: y), from: nil).y
        if height < 48 {
            showsFolderColumns = false
        } else {
            showsFolderColumns = true
            folderColumnsHeight = min(max(height, Self.minimumColumnsHeight), maximumColumnsHeight)
        }
    }

    override func layout() {
        super.layout()
        let barHeight: CGFloat = showsSortBar ? SortBarView.height : 0
        sortBar?.isHidden = !showsSortBar
        sortBar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let content = contentRect
        viewerView?.frame = content

        guard let folderColumns, let divider, !isViewerMode else {
            folderColumns?.isHidden = true
            divider?.isHidden = true
            browserView?.frame = content
            emptyState?.frame = content
            return
        }
        let top = columnsTop
        divider.isHidden = false
        var gridTop = content.maxY
        if showsFolderColumns {
            let height = min(max(folderColumnsHeight, Self.minimumColumnsHeight), maximumColumnsHeight)
            folderColumns.isHidden = false
            folderColumns.frame = NSRect(x: 0, y: top - height, width: bounds.width, height: height)
            divider.frame = NSRect(x: 0, y: top - height - 4, width: bounds.width, height: 7)
            gridTop = top - height
        } else {
            // Collapsed: an invisible strip under the toolbar to drag the columns back down.
            folderColumns.isHidden = true
            divider.frame = NSRect(x: 0, y: top - 5, width: bounds.width, height: 5)
        }
        let grid = NSRect(x: 0, y: content.minY, width: bounds.width, height: max(0, gridTop - content.minY))
        browserView?.frame = grid
        emptyState?.frame = grid
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
