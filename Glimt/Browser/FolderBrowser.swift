import AppKit

/// One folder in the columns. Children (folders only) are listed lazily, off the main thread,
/// the first time the folder is opened.
@MainActor
final class FolderNode: NSObject {
    let url: URL
    let title: String
    var children: [FolderNode]?
    private var isLoading = false

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func setChildren(_ urls: [URL]) {
        children = urls.map { FolderNode(url: $0, title: $0.lastPathComponent) }
    }

    /// Lists subfolders in the background; `done` runs on the main actor once they are known.
    func loadChildren(_ done: @escaping @MainActor () -> Void) {
        if children != nil { return done() }
        guard !isLoading else { return }
        isLoading = true
        let url = self.url
        Task {
            let urls = await Task.detached(priority: .userInitiated) { Self.subfolders(of: url) }.value
            self.isLoading = false
            self.setChildren(urls)
            done()
        }
    }

    func loadChildren() async {
        if children != nil { return }
        await withCheckedContinuation { continuation in
            loadChildren { continuation.resume() }
        }
    }

    nonisolated static func subfolders(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        return contents
            .filter {
                guard let values = try? $0.resourceValues(forKeys: Set(keys)) else { return false }
                return values.isDirectory == true && values.isPackage != true
            }
            .map { url.appendingPathComponent($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Every measurement in the columns, on the same 8 / 16 / 24 scale as the grid: text starts
/// 16 pt from a column's edge, so the first column's names line up with the thumbnails below.
private enum ColumnMetrics {
    static let width: CGFloat = 192
    static let rowHeight: CGFloat = 24
    static let textInset: CGFloat = 16
    /// The bookmark tick: 3 × 14 pt, 6 pt to the left of the name.
    static let tickX: CGFloat = 7
    static let tickWidth: CGFloat = 3
    static let tickHeight: CGFloat = 14
    static let verticalPadding: CGFloat = 8
    /// Gap between the places and the volumes in the first column.
    static let groupGap: CGFloat = 8
}

/// Phoenix Slides' directory listing: columns of folders above the thumbnails. The first column
/// holds the usual places and then every mounted volume; clicking a folder shows it in the grid,
/// and opening a folder any other way moves the columns to match. Arrow keys walk the tree
/// (← → between columns) and typing a name jumps to it.
@MainActor
final class FolderBrowserController: NSObject {
    let view = FolderColumnsView()
    /// The user picked a folder in the columns.
    var onOpen: ((URL) -> Void)?

    private let root = FolderNode(url: URL(fileURLWithPath: "/"), title: "")
    fileprivate private(set) var placeCount = 0
    private var columns: [FolderColumn] = []
    /// The selected folder in each column, left to right; the last one is the open folder.
    private var path: [FolderNode] = []
    private var isApplying = false
    private var revealGeneration = 0
    private var pendingOpen: DispatchWorkItem?

    var selectedURL: URL? { path.last?.url }

    /// The column whose selection is the open folder.
    func isCurrentColumn(_ index: Int) -> Bool {
        index == path.count - 1
    }

    /// The table showing the open folder's row (self-test hook for keyboard navigation).
    var currentTable: NSTableView? {
        path.isEmpty ? nil : columns[path.count - 1].table
    }

    override init() {
        super.init()
        reloadRoots()
        rebuildColumns()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }
        // Folders listed before permission was given came back empty; list them again.
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged(_:)), name: .folderAccessDidChange, object: nil)
    }

    // MARK: - Roots

    private func reloadRoots() {
        let fileManager = FileManager.default
        let home = FolderAccess.home
        // In the sandbox Glimt can't look at these before it is allowed in; they always exist.
        let places = ([home] + ["Desktop", "Documents", "Downloads", "Pictures", "Movies"].map { home.appendingPathComponent($0) })
            .filter { FolderAccess.isSandboxed || fileManager.fileExists(atPath: $0.path) }
        let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
        placeCount = places.count
        root.children = (places + volumes).map { url in
            // The home folder's display name is the account name; call it what it is.
            FolderNode(url: url, title: url == home ? String(localized: "Home") : fileManager.displayName(atPath: url.path))
        }
    }

    @objc private func volumesChanged(_ notification: Notification) {
        let current = selectedURL
        reloadRoots()
        path = []
        rebuildColumns()
        if let current { reveal(current) }
    }

    /// The first-column entry a folder belongs under: the deepest place or volume containing it.
    private func rootNode(for url: URL) -> FolderNode? {
        let path = url.standardizedFileURL.path
        return (root.children ?? [])
            .filter { node in
                let rootPath = node.url.standardizedFileURL.path
                return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
            }
            .max { $0.url.path.count < $1.url.path.count }
    }

    // MARK: - Columns

    /// Column i lists the children of `[root] + path` at i, with `path[i]` selected.
    private func rebuildColumns() {
        let parents = [root] + path
        var rebuilt: [FolderColumn] = []
        for (index, parent) in parents.enumerated() {
            if index < columns.count, columns[index].parent === parent {
                rebuilt.append(columns[index])
            } else {
                rebuilt.append(FolderColumn(index: index, parent: parent, owner: self))
            }
        }
        columns = rebuilt
        isApplying = true
        for column in columns {
            column.reloadRows()
            column.select(column.index < path.count ? path[column.index] : nil)
        }
        isApplying = false
        view.setColumns(columns.map(\.scrollView))
        view.scrollToLastColumn()
        for column in columns { column.centreSelection() }

        if let last = parents.last, last.children == nil {
            last.loadChildren { [weak self] in
                guard let self, self.columns.last?.parent === last else { return }
                self.columns.last?.reloadRows()
            }
        }
    }

    fileprivate func selectionChanged(in column: FolderColumn) {
        guard !isApplying else { return }
        let row = column.table.selectedRow
        guard column.rows.indices.contains(row), let node = column.rows[row] else { return }
        path = Array(path.prefix(column.index)) + [node]
        rebuildColumns()
        scheduleOpen(node.url)
    }

    /// ← : back to the parent folder, keeping its column of children in view.
    fileprivate func moveLeft(from column: FolderColumn) {
        guard column.index > 0 else { return }
        path = Array(path.prefix(column.index))
        rebuildColumns()
        view.window?.makeFirstResponder(columns[column.index - 1].table)
        if let parent = path.last { scheduleOpen(parent.url) }
    }

    /// → : into the selected folder's first subfolder.
    fileprivate func moveRight(from column: FolderColumn) {
        guard column.index + 1 < columns.count else { return }
        let next = columns[column.index + 1]
        guard let first = next.rows.firstIndex(where: { $0 != nil }) else { return }
        view.window?.makeFirstResponder(next.table)
        next.table.selectRowIndexes([first], byExtendingSelection: false)
    }

    private func scheduleOpen(_ url: URL) {
        pendingOpen?.cancel()
        // Arrow keys move through folders quickly; open only where the user settles.
        let isKey = NSApp.currentEvent?.type == .keyDown
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onOpen?(url) }
        }
        pendingOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isKey ? 0.18 : 0), execute: work)
    }

    // MARK: - Following the grid

    /// Moves the columns to show `folder`, listing any ancestors that aren't known yet.
    /// `subfolders`, when the caller already has them (the folder model just scanned it), fill
    /// the next column without touching the disk again.
    func reveal(_ folder: URL, subfolders: [URL]? = nil) {
        revealGeneration += 1
        let generation = revealGeneration
        Task {
            guard let start = rootNode(for: folder) else { return }
            var chain = [start]
            let relative = String(folder.standardizedFileURL.path.dropFirst(start.url.standardizedFileURL.path.count))
            for name in relative.split(separator: "/").map(String.init) {
                let parent = chain[chain.count - 1]
                await parent.loadChildren()
                guard generation == revealGeneration else { return }
                if let child = parent.children?.first(where: { $0.title == name }) {
                    chain.append(child)
                } else {
                    // A hidden folder (opened with Go to Folder, say): add it so the path is complete.
                    let url = parent.url.appendingPathComponent(name)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { break }
                    let child = FolderNode(url: url, title: name)
                    var siblings = parent.children ?? []
                    let position = siblings.firstIndex { $0.title.localizedStandardCompare(name) == .orderedDescending } ?? siblings.count
                    siblings.insert(child, at: position)
                    parent.children = siblings
                    chain.append(child)
                }
            }
            if let subfolders, chain.last?.url.standardizedFileURL.path == folder.standardizedFileURL.path {
                chain.last?.setChildren(subfolders)
            }
            guard generation == revealGeneration else { return }
            path = chain
            rebuildColumns()
        }
    }
}

/// One column: a plain table of folder names with our own selection pill.
@MainActor
final class FolderColumn: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let index: Int
    let parent: FolderNode
    let scrollView = NSScrollView()
    let table = FolderColumnTable()
    /// Folders in order; `nil` is the gap between places and volumes in the first column.
    private(set) var rows: [FolderNode?] = []
    private weak var owner: FolderBrowserController?

    init(index: Int, parent: FolderNode, owner: FolderBrowserController) {
        self.index = index
        self.parent = parent
        self.owner = owner
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.rowHeight = ColumnMetrics.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.column = self

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
    }

    func reloadRows() {
        var folders: [FolderNode?] = parent.children ?? []
        if index == 0, let owner, owner.placeCount < folders.count {
            folders.insert(nil, at: owner.placeCount)
        }
        rows = folders
        table.reloadData()
    }

    func select(_ node: FolderNode?) {
        guard let node, let row = rows.firstIndex(where: { $0 === node }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// Brings the selected folder to the middle of its column (unless it is already in view), so
    /// it never ends up half cut off at an edge. Call once the column has its final size.
    func centreSelection() {
        let row = table.selectedRow
        guard row >= 0 else { return }
        table.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let rect = table.rect(ofRow: row)
        guard !clip.bounds.insetBy(dx: 0, dy: ColumnMetrics.rowHeight / 2).contains(rect) else { return }
        var bounds = clip.bounds
        // Whole rows only, so rows stay level with the neighbouring columns.
        let rowHeight = ColumnMetrics.rowHeight
        bounds.origin.y = ((rect.midY - bounds.height / 2) / rowHeight).rounded() * rowHeight
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row] == nil ? ColumnMetrics.groupGap : ColumnMetrics.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row] != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = FolderRowView()
        rowView.isCurrent = owner?.isCurrentColumn(index) ?? false
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let node = rows[row] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("folder")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FolderCellView ?? {
            let cell = FolderCellView()
            cell.identifier = identifier
            return cell
        }()
        cell.textField?.stringValue = node.title
        cell.toolTip = FolderAccess.abbreviated(node.url.path)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows[row]?.title
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        owner?.selectionChanged(in: self)
    }

    fileprivate func moveLeft() { owner?.moveLeft(from: self) }
    fileprivate func moveRight() { owner?.moveRight(from: self) }
}

/// ← and → move between columns, as in Finder.
final class FolderColumnTable: NSTableView {
    fileprivate weak var column: FolderColumn?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
        case NSLeftArrowFunctionKey: column?.moveLeft()
        case NSRightArrowFunctionKey: column?.moveRight()
        default: super.keyDown(with: event)
        }
    }
}

/// Marks the selected folders with a small tick in the left margin, like a bookmark tab: grey
/// for the folders along the path, the accent colour for the open folder. (Chosen over a filled
/// pill and four other styles; see docs/design/highlight-options.png.)
final class FolderRowView: NSTableRowView {
    /// This row's column holds the open folder.
    var isCurrent = false

    override var isSelected: Bool {
        didSet { updateCells() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateCells()
    }

    private func updateCells() {
        for case let cell as FolderCellView in subviews {
            cell.setSelected(isSelected)
        }
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (isCurrent ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        let tick = NSRect(x: ColumnMetrics.tickX, y: bounds.midY - ColumnMetrics.tickHeight / 2,
                          width: ColumnMetrics.tickWidth, height: ColumnMetrics.tickHeight)
        NSBezierPath(roundedRect: tick, xRadius: ColumnMetrics.tickWidth / 2, yRadius: ColumnMetrics.tickWidth / 2).fill()
    }
}

/// Name and chevron, both centred on the row; selected names are set in semibold.
final class FolderCellView: NSTableCellView {
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ColumnMetrics.textInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ColumnMetrics.textInset),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The row draws the tick; a selected row must not switch the text to "on accent" colours.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {}
    }

    func setSelected(_ selected: Bool) {
        textField?.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
    }
}

/// The pane: one step greyer than the content below, so it reads as navigation; columns side by
/// side with hairlines between them, a hairline along the bottom.
final class FolderColumnsView: NSView {
    private let scrollView = NSScrollView()
    private let strip = NSView()
    private let bottomSeparator = NSBox()
    private var columnViews: [NSView] = []
    private var dividers: [NSBox] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.documentView = strip
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
        bottomSeparator.boxType = .separator
        addSubview(bottomSeparator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.navigationBackground.cgColor
        }
    }

    func setColumns(_ views: [NSView]) {
        guard views.map(ObjectIdentifier.init) != columnViews.map(ObjectIdentifier.init) else { return }
        for view in columnViews where !views.contains(where: { $0 === view }) { view.removeFromSuperview() }
        for view in views where view.superview !== strip { strip.addSubview(view) }
        columnViews = views
        while dividers.count < views.count {
            let divider = NSBox()
            divider.boxType = .separator
            strip.addSubview(divider)
            dividers.append(divider)
        }
        needsLayout = true
    }

    func scrollToLastColumn() {
        layoutSubtreeIfNeeded()
        guard let last = columnViews.last else { return }
        strip.scrollToVisible(last.frame)
    }

    override func layout() {
        super.layout()
        let height = bounds.height - 1
        scrollView.frame = NSRect(x: 0, y: 1, width: bounds.width, height: height)
        bottomSeparator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let width = ColumnMetrics.width
        strip.frame = NSRect(x: 0, y: 0, width: max(bounds.width, CGFloat(columnViews.count) * width), height: height)
        // Padding comes from the frame, not content insets, so rows clip at a clean edge
        // instead of sliding into the padding.
        let padding = ColumnMetrics.verticalPadding
        let available = max(0, height - padding * 2)
        for (index, view) in columnViews.enumerated() {
            // Whole rows only (the first column also has its places/volumes gap), so no column
            // ends on a sliver of a row.
            let visible = index == 0 ? available : (available / ColumnMetrics.rowHeight).rounded(.down) * ColumnMetrics.rowHeight
            view.frame = NSRect(x: CGFloat(index) * width, y: padding + available - visible, width: width - 1, height: visible)
        }
        for (index, divider) in dividers.enumerated() {
            divider.isHidden = index >= columnViews.count
            divider.frame = NSRect(x: CGFloat(index + 1) * width - 1, y: 0, width: 1, height: height)
        }
    }
}

/// The draggable strip between the folder columns and the thumbnails (the visible line is the
/// columns pane's own separator). Dragging it to the top hides the columns; dragging down from
/// the top edge brings them back.
final class FolderBrowserDivider: NSView {
    var onDrag: ((_ windowY: CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
