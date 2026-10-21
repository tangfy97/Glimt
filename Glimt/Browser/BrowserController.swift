import AppKit

@MainActor
protocol BrowserControllerDelegate: AnyObject {
    func browser(_ browser: BrowserController, openMediaAt index: Int)
    func browser(_ browser: BrowserController, openFolder url: URL)
    func browserSelectionDidChange(_ browser: BrowserController)
    func browserContextMenu(_ browser: BrowserController) -> NSMenu?
}

/// The thumbnail grid: subfolders first, then the folder's images and videos.
@MainActor
final class BrowserController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    weak var delegate: BrowserControllerDelegate?

    let scrollView = GridScrollView()
    let collectionView = GridCollectionView()
    private let layout = GridLayout()
    private let model: FolderModel
    private let thumbnails = ThumbnailStore.shared
    private lazy var folderIcon = NSWorkspace.shared.icon(for: .folder)

    private var pinchAnchor: (index: Int, relative: CGPoint, pointInView: CGPoint)?

    init(model: FolderModel) {
        self.model = model
        super.init()
        layout.tileSide = CGFloat(Preferences.thumbnailSize)
        layout.showsNames = Preferences.showFileNames

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.browser = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [Palette.gridBackground]
        collectionView.register(ThumbnailCell.self, forItemWithIdentifier: ThumbnailCell.identifier)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.gridBackground
        scrollView.browser = self
    }

    // MARK: - Data

    private var folderCount: Int { model.folders.count }

    func item(at index: Int) -> Item? {
        if index < folderCount { return model.folders[index] }
        let media = index - folderCount
        return model.media.indices.contains(media) ? model.media[media] : nil
    }

    func reload() {
        let selected = Set(selectedItems.map(\.url))
        collectionView.reloadData()
        let paths = (0..<(folderCount + model.media.count)).compactMap { index -> IndexPath? in
            guard let item = item(at: index), selected.contains(item.url) else { return nil }
            return IndexPath(item: index, section: 0)
        }
        collectionView.selectionIndexPaths = Set(paths)
    }

    var selectedItems: [Item] {
        collectionView.selectionIndexPaths.sorted().compactMap { item(at: $0.item) }
    }

    var selectedMediaIndices: [Int] {
        collectionView.selectionIndexPaths.map { $0.item - folderCount }.filter { $0 >= 0 }.sorted()
    }

    func selectMedia(at index: Int, scroll: Bool) {
        let path = IndexPath(item: index + folderCount, section: 0)
        guard path.item < collectionView.numberOfItems(inSection: 0) else { return }
        collectionView.selectionIndexPaths = [path]
        if scroll { scrollToVisible(path) }
    }

    func selectAll() {
        collectionView.selectAll(nil)
    }

    private func scrollToVisible(_ path: IndexPath) {
        let frame = layout.frame(at: path.item)
        let visible = scrollView.contentView.bounds.insetBy(dx: 0, dy: scrollView.contentInsets.top / 2)
        if !visible.contains(frame) {
            collectionView.scrollToItems(at: [path], scrollPosition: .centeredVertically)
        }
    }

    func focus() {
        collectionView.window?.makeFirstResponder(collectionView)
    }

    // MARK: - Transition support

    /// The on-screen rect of the media item's picture, in `view`'s coordinates.
    func imageFrame(forMedia index: Int, in view: NSView) -> NSRect? {
        let path = IndexPath(item: index + folderCount, section: 0)
        collectionView.layoutSubtreeIfNeeded()
        guard let cell = collectionView.item(at: path) as? ThumbnailCell, cell.tile.imageContents != nil else { return nil }
        let rect = view.convert(cell.tile.imageRect, from: cell.tile)
        let visible = view.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        return visible.intersects(rect) ? rect : nil
    }

    func thumbnail(for url: URL) -> Thumbnail? {
        thumbnails.cached(url, pixels: 512)?.thumbnail
    }

    // MARK: - Thumbnail size

    var tileSide: CGFloat {
        get { layout.tileSide }
        set { setTileSide(newValue, anchor: nil) }
    }

    static let tileRange: ClosedRange<CGFloat> = 72...360

    private var pixelTier: Int {
        ThumbnailStore.pixels(forPoints: layout.cellWidth, scale: collectionView.window?.backingScaleFactor ?? 2)
    }

    /// Changes the tile size while keeping the tile under `anchor` (a window point) still.
    func setTileSide(_ side: CGFloat, anchor windowPoint: NSPoint?) {
        let clamped = min(max(side, Self.tileRange.lowerBound), Self.tileRange.upperBound)
        guard clamped != layout.tileSide else { return }
        let tierBefore = pixelTier
        let clip = scrollView.contentView
        let pointInView = windowPoint.map { clip.convert($0, from: nil) } ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.minY + 1)
        let anchor = layout.index(nearest: pointInView).map { index -> (Int, CGPoint) in
            let frame = layout.frame(at: index)
            return (index, CGPoint(x: (pointInView.x - frame.minX) / frame.width, y: (pointInView.y - frame.minY) / frame.height))
        }
        let offsetInClip = NSPoint(x: pointInView.x - clip.bounds.minX, y: pointInView.y - clip.bounds.minY)

        layout.tileSide = clamped
        layout.computeColumns()
        collectionView.setFrameSize(layout.collectionViewContentSize)
        if let (index, relative) = anchor {
            let frame = layout.frame(at: index)
            let target = NSPoint(x: frame.minX + relative.x * frame.width, y: frame.minY + relative.y * frame.height)
            var bounds = clip.bounds
            bounds.origin.y = target.y - offsetInClip.y
            clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        if pixelTier != tierBefore { refreshVisibleThumbnails() }
    }

    func pinchEnded() {
        Preferences.thumbnailSize = Double(layout.tileSide)
        refreshVisibleThumbnails()
    }

    func applyPreferences() {
        layout.showsNames = Preferences.showFileNames
        for case let cell as ThumbnailCell in collectionView.visibleItems() {
            cell.tile.showsName = layout.showsNames
        }
    }

    func refreshVisibleThumbnails() {
        for path in collectionView.indexPathsForVisibleItems() {
            if let cell = collectionView.item(at: path) as? ThumbnailCell, let item = item(at: path.item) {
                loadThumbnail(for: item, into: cell)
            }
        }
    }

    /// Benchmark: whether every visible media tile has its thumbnail.
    var visibleThumbnailsLoaded: Bool {
        let cells = collectionView.visibleItems().compactMap { $0 as? ThumbnailCell }
        return !cells.isEmpty && cells.allSatisfy { $0.tile.imageContents != nil }
    }

    func reloadThumbnail(for url: URL) {
        thumbnails.invalidate(url)
        refreshVisibleThumbnails()
    }

    // MARK: - Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        folderCount + model.media.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: ThumbnailCell.identifier, for: indexPath) as! ThumbnailCell
        guard let item = item(at: indexPath.item) else { return cell }
        cell.representedURL = item.url
        cell.tile.showsName = layout.showsNames
        cell.tile.configure(name: item.name, tags: item.tags.compactMap(FinderTags.color(for:)), duration: nil)
        if item.kind == .folder {
            cell.tile.setImage(folderIcon, aspect: 1)
        } else {
            loadThumbnail(for: item, into: cell)
        }
        return cell
    }

    private func loadThumbnail(for item: Item, into cell: ThumbnailCell) {
        guard item.kind != .folder else { return }
        let pixels = pixelTier
        let cached = thumbnails.cached(item.url, pixels: pixels)
        if let cached { show(cached.thumbnail, in: cell) }
        guard cached?.exact != true else { return }
        thumbnails.cancel(cell.token)
        cell.token = thumbnails.request(item, pixels: pixels) { [weak self, weak cell] thumbnail in
            guard let self, let cell, cell.representedURL == item.url else { return }
            cell.token = nil
            self.show(thumbnail, in: cell)
        }
    }

    private func show(_ thumbnail: Thumbnail, in cell: ThumbnailCell) {
        let size = thumbnail.image.sourceSize
        cell.tile.setImage(thumbnail.image.surface, aspect: size.height > 0 ? size.width / size.height : 1)
        if let duration = thumbnail.duration { cell.tile.setDuration(duration) }
    }

    // MARK: - Delegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.browserSelectionDidChange(self)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.browserSelectionDidChange(self)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        item(at: indexPath.item)?.url as NSURL?
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let cell = item as? ThumbnailCell else { return }
        thumbnails.cancel(cell.token)
        cell.token = nil
    }

    // MARK: - Events from the views

    func open(at index: Int) {
        guard let item = item(at: index) else { return }
        if item.kind == .folder {
            delegate?.browser(self, openFolder: item.url)
        } else {
            delegate?.browser(self, openMediaAt: index - folderCount)
        }
    }

    func openSelection() {
        guard let first = collectionView.selectionIndexPaths.min() else {
            if !model.media.isEmpty { delegate?.browser(self, openMediaAt: 0) }
            return
        }
        open(at: first.item)
    }

    func contextMenu() -> NSMenu? {
        delegate?.browserContextMenu(self)
    }

    func pinch(_ event: NSEvent) {
        setTileSide(layout.tileSide * (1 + event.magnification), anchor: event.locationInWindow)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { pinchEnded() }
    }
}

final class GridScrollView: NSScrollView {
    weak var browser: BrowserController?

    override func magnify(with event: NSEvent) {
        browser?.pinch(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let browser {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            browser.setTileSide(browser.tileSide * exp(delta), anchor: event.locationInWindow)
            return
        }
        super.scrollWheel(with: event)
    }
}

final class GridCollectionView: NSCollectionView {
    weak var browser: BrowserController?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) } ?? 0
        let opens = modifiers.isEmpty ? [0x0D, 0x03, 0x20].contains(key) // return, enter, space
            : modifiers == .command && key == NSDownArrowFunctionKey
        if opens { browser?.openSelection() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            browser?.open(at: path.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        return browser?.contextMenu()
    }
}
