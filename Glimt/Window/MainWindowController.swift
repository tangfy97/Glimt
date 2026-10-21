import AppKit
import Carbon.HIToolbox

/// One browsing window: the grid and the viewer over a shared folder model, the sort bar,
/// the toolbar, and every command in the menus.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    enum Mode { case browser, viewer }

    let model = FolderModel()
    let operations = FileOperations()
    private(set) lazy var browser = BrowserController(model: model)
    private(set) lazy var viewer = ViewerController(model: model)
    let inspector = InspectorController()

    private let rootView = RootView()
    private let sortBar = SortBarView()
    private let emptyState = PlaceholderView()
    private(set) var mode = Mode.browser
    private var isTransitioning = false
    private var enteredFullScreenForSlideshow = false
    private var searchItem: NSSearchToolbarItem?
    private var sizeSlider: NSSlider?

    var onOpenedURL: ((URL) -> Void)?
    /// Benchmark / self-test hook: fires after each folder load.
    var onFolderLoaded: (() -> Void)?

    init() {
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Glimt"
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        super.init(window: window)

        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleWindowKey(event) ?? false }
        if !window.setFrameUsingName("Main") { window.center() }
        window.setFrameAutosaveName("Main")

        rootView.browserView = browser.scrollView
        rootView.viewerView = viewer.view
        rootView.sortBar = sortBar
        rootView.emptyState = emptyState
        rootView.showsSortBar = Preferences.showSortBar
        viewer.view.isHidden = true
        emptyState.show(.welcome)

        browser.delegate = self
        viewer.delegate = self
        sortBar.delegate = self
        operations.model = model
        operations.onError = { [weak self] message in self?.presentError(message) }
        operations.onContentsChanged = { [weak self] url in
            self?.browser.reloadThumbnail(for: url)
            self?.viewer.invalidate(url)
            self?.inspector.refresh()
        }
        model.observe { [weak self] change in self?.modelChanged(change) }

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Opening

    /// Opens a folder in the grid, or an image straight in the viewer with its folder behind it.
    func open(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        onOpenedURL?(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if mode == .viewer { closeViewer(animated: false) }
        searchItem?.searchField.stringValue = ""
        model.searchText = ""
        window?.representedURL = folder
        Task {
            await model.load(folder)
            if !isDirectory, let index = model.media.firstIndex(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                openViewer(at: index, animated: false)
            } else {
                browser.collectionView.scroll(.zero)
                browser.focus()
            }
            onFolderLoaded?()
        }
    }

    private func modelChanged(_ change: FolderModel.Change) {
        browser.reload()
        if model.isLoading {
            emptyState.show(.loading)
        } else if model.folder == nil {
            emptyState.show(.welcome)
        } else if model.folders.isEmpty && model.media.isEmpty {
            emptyState.show(model.isFiltered ? .noMatches : .noImages(folder: model.folder?.lastPathComponent ?? ""))
        } else {
            emptyState.isHidden = true
        }
        if mode == .browser { inspector.update(browser.selectedItems.first) }
        updateChrome()
    }

    // MARK: - Mode switching

    func openViewer(at index: Int, animated: Bool) {
        guard model.media.indices.contains(index), !isTransitioning else { return }
        let item = model.media[index]
        let thumbnail = browser.thumbnail(for: item.url)
        let start = animated ? browser.imageFrame(forMedia: index, in: rootView) : nil
        mode = .viewer
        viewer.view.isHidden = false
        viewer.show(index: index, seed: thumbnail)
        updateChrome()

        guard let start, let thumbnail else {
            browser.scrollView.isHidden = true
            return
        }
        let end = rootView.convert(viewer.view.fitRect(for: thumbnail.image.sourceSize), from: viewer.view)
        runTransition(contents: thumbnail.image.surface, from: start, to: end, appearing: true) { [weak self] in
            self?.browser.scrollView.isHidden = true
        }
    }

    func closeViewer(animated: Bool) {
        guard mode == .viewer, !isTransitioning else { return }
        let index = viewer.index
        let fitted = viewer.view.fittedImage
        mode = .browser
        browser.scrollView.isHidden = false
        browser.selectMedia(at: index, scroll: true)
        browser.focus()
        let end = animated ? browser.imageFrame(forMedia: index, in: rootView) : nil
        viewer.deactivate()
        updateChrome()

        guard let fitted, let end else {
            viewer.view.isHidden = true
            return
        }
        let start = rootView.convert(fitted.rect, from: viewer.view)
        runTransition(contents: fitted.contents, from: start, to: end, appearing: false) { [weak self] in
            self?.viewer.view.isHidden = true
        }
    }

    /// The picture flies between its grid tile and its fitted place in the viewer while the
    /// viewer's backdrop fades. The flying layer starts from the bitmap already on screen,
    /// so the first frame is immediate.
    private func runTransition(contents: Any, from start: NSRect, to end: NSRect, appearing: Bool, completion: @escaping () -> Void) {
        guard let rootLayer = rootView.layer else { return completion() }
        isTransitioning = true
        let flyer = CALayer()
        flyer.contents = contents
        flyer.contentsGravity = .resize
        flyer.minificationFilter = .trilinear
        flyer.zPosition = 1000
        flyer.actions = ["contents": NSNull()]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flyer.frame = start
        rootLayer.addSublayer(flyer)
        viewer.view.setContentHidden(true)
        viewer.view.alphaValue = appearing ? 0 : 1
        CATransaction.commit()

        let duration = 0.32
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            viewer.view.animator().alphaValue = appearing ? 1 : 0
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.viewer.view.setContentHidden(false)
                self.viewer.view.alphaValue = 1
                completion()
                flyer.removeFromSuperlayer()
                self.isTransitioning = false
            }
        }
        flyer.frame = end
        CATransaction.commit()
    }

    private func updateChrome() {
        guard let window else { return }
        switch mode {
        case .browser:
            window.title = model.folder?.lastPathComponent ?? "Glimt"
            if model.isLoading {
                window.subtitle = String(localized: "Loading…")
            } else if model.folder != nil {
                let count = model.media.count
                var subtitle = String(localized: "\(count) items")
                if model.isFiltered { subtitle += String(localized: " · filtered") }
                let selected = browser.collectionView.selectionIndexPaths.count
                if selected > 1 { subtitle += String(localized: " · \(selected) selected") }
                window.subtitle = subtitle
            } else {
                window.subtitle = ""
            }
        case .viewer:
            guard let item = viewer.currentItem else { return }
            window.title = item.name
            var subtitle = "\(viewer.index + 1) / \(viewer.items.count)"
            if let shown = viewer.shown, shown.url == item.url {
                subtitle += "  ·  \(Int(shown.sourceSize.width)) × \(Int(shown.sourceSize.height))"
            }
            window.subtitle = subtitle
        }
        sizeSlider?.doubleValue = Double(browser.tileSide)
        sizeSlider?.isEnabled = mode == .browser
    }

    // MARK: - Keys that bypass the menus

    /// Number keys sort (⇧ copies, ⌥ chooses the folder). Handled before the menus so they
    /// work identically in the grid and the viewer, and never while typing in a text field.
    private func handleWindowKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !(window?.firstResponder is NSText) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        guard let slot = digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
        if event.isARepeat { return true }
        if modifiers.contains(.option) {
            chooseTarget(slot)
        } else {
            sort(to: slot, copy: modifiers.contains(.shift) != Preferences.numberKeysCopy)
        }
        return true
    }

    // MARK: - File commands

    /// The files a command acts on: the image in the viewer, or the grid selection.
    private func targetURLs(includingFolders: Bool = false) -> [URL] {
        switch mode {
        case .viewer:
            return viewer.currentItem.map { [$0.url] } ?? []
        case .browser:
            return browser.selectedItems.filter { includingFolders || $0.isMedia }.map(\.url)
        }
    }

    func sort(to slot: Int, copy: Bool) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return NSSound.beep() }
        guard let folder = SortTargets.shared.folder(at: slot) else {
            Task {
                if await SortTargets.shared.choose(for: slot, attachedTo: window) != nil { sort(to: slot, copy: copy) }
            }
            return
        }
        if copy { operations.copy(urls, into: folder) } else { operations.move(urls, into: folder) }
        sortBar.flash(slot)
        if mode == .viewer {
            viewer.view.flashMessage((copy ? "⧉ " : "→ ") + "\(slot + 1)  \(folder.lastPathComponent)")
        }
    }

    private func chooseTarget(_ slot: Int) {
        Task { _ = await SortTargets.shared.choose(for: slot, attachedTo: window) }
    }

    @objc func sortToTarget(_ sender: NSMenuItem) {
        sort(to: sender.tag % 10, copy: sender.tag >= 10)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = targetURLs(includingFolders: true)
        guard !urls.isEmpty else { return NSSound.beep() }
        operations.trash(urls)
        if mode == .viewer { viewer.view.flashMessage(String(localized: "Moved to Trash")) }
    }

    @objc func renameItem(_ sender: Any?) {
        guard let url = targetURLs(includingFolders: true).first, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename “\(url.lastPathComponent)”")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.operations.rename(url, to: field.stringValue)
            }
        }
        // Select the name without the extension, as Finder does.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let base = (url.lastPathComponent as NSString).deletingPathExtension
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }
    }

    @objc func rotateLeft(_ sender: Any?) { rotate(clockwise: false) }
    @objc func rotateRight(_ sender: Any?) { rotate(clockwise: true) }

    private func rotate(clockwise: Bool) {
        let urls = targetURLs().filter { model.item(for: $0)?.kind == .image }
        guard !urls.isEmpty else { return NSSound.beep() }
        operations.rotate(urls, clockwise: clockwise)
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        let tags = FinderTags.all
        guard tags.indices.contains(sender.tag) else { return }
        let urls = targetURLs(includingFolders: true)
        guard !urls.isEmpty else { return NSSound.beep() }
        operations.toggleTag(tags[sender.tag].name, on: urls)
        if mode == .viewer, let item = viewer.currentItem {
            let has = item.tags.contains(tags[sender.tag].name)
            viewer.view.flashMessage((has ? "● " : "○ ") + tags[sender.tag].name)
        }
    }

    @objc func clearTags(_ sender: Any?) {
        operations.clearTags(on: targetURLs(includingFolders: true))
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = targetURLs(includingFolders: true)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [model.folder].compactMap { $0 } : urls)
    }

    @objc func copy(_ sender: Any?) {
        let urls = targetURLs(includingFolders: true)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    @objc override func selectAll(_ sender: Any?) {
        if mode == .browser { browser.selectAll() }
    }

    @objc func openWithDefaultApp(_ sender: Any?) {
        for url in targetURLs(includingFolders: false) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Navigation commands

    @objc func goBack(_ sender: Any?) {
        if mode == .viewer { closeViewer(animated: true) } else { openEnclosingFolder(sender) }
    }

    @objc func openEnclosingFolder(_ sender: Any?) {
        guard let folder = model.folder, folder.path != "/" else { return }
        let parent = folder.deletingLastPathComponent()
        let previous = folder
        open(parent)
        // Select the folder we came from once the parent has loaded.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            while model.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
            if let index = model.folders.firstIndex(where: { $0.url.standardizedFileURL == previous.standardizedFileURL }) {
                browser.collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
                browser.collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
            }
        }
    }

    @objc func nextImage(_ sender: Any?) { if mode == .viewer { viewer.navigate(.next) } }
    @objc func previousImage(_ sender: Any?) { if mode == .viewer { viewer.navigate(.previous) } }
    @objc func firstImage(_ sender: Any?) { if mode == .viewer { viewer.navigate(.first) } }
    @objc func lastImage(_ sender: Any?) { if mode == .viewer { viewer.navigate(.last) } }

    @objc func showViewerOrGrid(_ sender: Any?) {
        if mode == .viewer { closeViewer(animated: true) } else { browser.openSelection() }
    }

    // MARK: - View commands

    @objc func zoomIn(_ sender: Any?) {
        if mode == .viewer { viewer.zoomIn() } else { setTileSide(browser.tileSide * 1.25) }
    }

    @objc func zoomOut(_ sender: Any?) {
        if mode == .viewer { viewer.zoomOut() } else { setTileSide(browser.tileSide / 1.25) }
    }

    @objc func zoomToActualSize(_ sender: Any?) { viewer.zoomToActualSize() }
    @objc func zoomToFit(_ sender: Any?) { viewer.zoomToFit() }

    private func setTileSide(_ side: CGFloat) {
        browser.tileSide = side
        browser.pinchEnded()
        updateChrome()
    }

    @objc private func thumbnailSliderChanged(_ sender: NSSlider) {
        browser.setTileSide(CGFloat(sender.doubleValue), anchor: nil)
        if NSApp.currentEvent?.type == .leftMouseUp { browser.pinchEnded() }
    }

    @objc func setSortKey(_ sender: NSMenuItem) {
        guard let key = FolderModel.SortKey.allCases[safe: sender.tag] else { return }
        model.sortKey = key
    }

    @objc func setSortAscending(_ sender: NSMenuItem) {
        model.ascending = sender.tag == 0
    }

    @objc func setKindFilter(_ sender: NSMenuItem) {
        model.kindFilter = FolderModel.KindFilter.allCases[safe: sender.tag] ?? .all
    }

    @objc func setTagFilter(_ sender: NSMenuItem) {
        let tags = FinderTags.all
        model.tagFilter = tags.indices.contains(sender.tag) ? tags[sender.tag].name : nil
    }

    @objc func toggleFileNames(_ sender: Any?) {
        UserDefaults.standard.set(!Preferences.showFileNames, forKey: Preferences.Key.showFileNames)
    }

    @objc func toggleSortBar(_ sender: Any?) {
        Preferences.showSortBar.toggle()
    }

    @objc func toggleInspector(_ sender: Any?) {
        inspector.update(mode == .viewer ? viewer.currentItem : browser.selectedItems.first)
        inspector.toggle(beside: window)
    }

    @objc func focusSearch(_ sender: Any?) {
        if mode == .viewer { closeViewer(animated: false) }
        searchItem?.beginSearchInteraction()
    }

    @objc func toggleSlideshow(_ sender: Any?) {
        if viewer.isSlideshowRunning {
            viewer.stopSlideshow()
            return
        }
        if mode == .browser {
            guard !model.media.isEmpty else { return NSSound.beep() }
            openViewer(at: browser.selectedMediaIndices.first ?? 0, animated: false)
        }
        if window?.styleMask.contains(.fullScreen) == false {
            enteredFullScreenForSlideshow = true
            window?.toggleFullScreen(nil)
        }
        viewer.startSlideshow()
    }

    @objc private func preferencesChanged() {
        browser.applyPreferences()
        if rootView.showsSortBar != Preferences.showSortBar && !viewer.isSlideshowRunning {
            rootView.showsSortBar = Preferences.showSortBar
        }
        viewer.view.needsLayout = true
    }

    private func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasTargets = !targetURLs(includingFolders: true).isEmpty
        switch item.action {
        case #selector(sortToTarget(_:)):
            let slot = item.tag % 10
            let folder = SortTargets.shared.folder(at: slot)
            let key = item.tag >= 10 ? "⇧\(slot + 1)" : "\(slot + 1)"
            item.title = "\(key)   " + (folder?.lastPathComponent ?? String(localized: "Choose Folder…"))
            return !targetURLs().isEmpty
        case #selector(moveToTrash(_:)), #selector(revealInFinder(_:)), #selector(copy(_:)), #selector(clearTags(_:)):
            return hasTargets
        case #selector(renameItem(_:)):
            return targetURLs(includingFolders: true).count == 1
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            return targetURLs().contains { model.item(for: $0)?.kind == .image }
        case #selector(toggleTag(_:)):
            let tags = FinderTags.all
            guard tags.indices.contains(item.tag) else { return false }
            let items = targetURLs(includingFolders: true).compactMap { model.item(for: $0) }
            item.state = !items.isEmpty && items.allSatisfy { $0.tags.contains(tags[item.tag].name) } ? .on : .off
            return !items.isEmpty
        case #selector(nextImage(_:)), #selector(lastImage(_:)):
            return mode == .viewer && viewer.index + 1 < viewer.items.count
        case #selector(previousImage(_:)), #selector(firstImage(_:)):
            return mode == .viewer && viewer.index > 0
        case #selector(zoomToActualSize(_:)), #selector(zoomToFit(_:)):
            return mode == .viewer && viewer.view.hasImage
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return mode == .browser || viewer.view.hasImage
        case #selector(openEnclosingFolder(_:)):
            return model.folder.map { $0.path != "/" } ?? false
        case #selector(selectAll(_:)):
            return mode == .browser && model.folder != nil
        case #selector(openWithDefaultApp(_:)):
            return !targetURLs().isEmpty
        case #selector(showViewerOrGrid(_:)):
            item.title = mode == .viewer ? String(localized: "Back to Grid") : String(localized: "Open in Viewer")
            return mode == .viewer || !model.media.isEmpty
        case #selector(setSortKey(_:)):
            item.state = FolderModel.SortKey.allCases[safe: item.tag] == model.sortKey ? .on : .off
            return true
        case #selector(setSortAscending(_:)):
            item.state = (item.tag == 0) == model.ascending ? .on : .off
            return true
        case #selector(setKindFilter(_:)):
            item.state = FolderModel.KindFilter.allCases[safe: item.tag] == model.kindFilter ? .on : .off
            return true
        case #selector(setTagFilter(_:)):
            let tags = FinderTags.all
            let name = tags.indices.contains(item.tag) ? tags[item.tag].name : nil
            item.state = name == model.tagFilter ? .on : .off
            return true
        case #selector(toggleFileNames(_:)):
            item.state = Preferences.showFileNames ? .on : .off
            return true
        case #selector(toggleSortBar(_:)):
            item.title = Preferences.showSortBar ? String(localized: "Hide Sort Bar") : String(localized: "Show Sort Bar")
            return true
        case #selector(toggleInspector(_:)):
            item.title = inspector.isVisible ? String(localized: "Hide Info") : String(localized: "Show Info")
            return true
        case #selector(toggleSlideshow(_:)):
            item.title = viewer.isSlideshowRunning ? String(localized: "Stop Slideshow") : String(localized: "Start Slideshow")
            return !model.media.isEmpty
        case #selector(goBack(_:)):
            return mode == .viewer || model.folder.map { $0.path != "/" } == true
        default:
            return true
        }
    }

    // MARK: - Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        operations.undoManager
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        viewer.view.usesFullScreenBackground = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        viewer.view.usesFullScreenBackground = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        enteredFullScreenForSlideshow = false
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if mode == .viewer { viewer.reloadCurrent() }
    }
}

// MARK: - Browser, viewer and sort bar delegates

extension MainWindowController: BrowserControllerDelegate {
    func browser(_ browser: BrowserController, openMediaAt index: Int) {
        openViewer(at: index, animated: true)
    }

    func browser(_ browser: BrowserController, openFolder url: URL) {
        open(url)
    }

    func browserSelectionDidChange(_ browser: BrowserController) {
        inspector.update(browser.selectedItems.first)
        updateChrome()
    }

    func browserContextMenu(_ browser: BrowserController) -> NSMenu? {
        guard !browser.selectedItems.isEmpty else { return nil }
        let menu = NSMenu()
        let hasMedia = browser.selectedItems.contains { $0.isMedia }
        if hasMedia {
            menu.addItem(withTitle: String(localized: "Open in Viewer"), action: #selector(showViewerOrGrid(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Open with Default App"), action: #selector(openWithDefaultApp(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(revealInFinder(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        if hasMedia {
            let sortMenu = NSMenu()
            for slot in 0..<SortTargets.count {
                let item = sortMenu.addItem(withTitle: "", action: #selector(sortToTarget(_:)), keyEquivalent: "")
                item.tag = slot
            }
            menu.addItem(withTitle: String(localized: "Move To"), action: nil, keyEquivalent: "").submenu = sortMenu
            menu.addItem(withTitle: String(localized: "Rotate Left"), action: #selector(rotateLeft(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Rotate Right"), action: #selector(rotateRight(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: String(localized: "Rename…"), action: #selector(renameItem(_:)), keyEquivalent: "")
        menu.addItem(MainMenu.tagsItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Move to Trash"), action: #selector(moveToTrash(_:)), keyEquivalent: "")
        return menu
    }
}

extension MainWindowController: ViewerControllerDelegate {
    func viewerController(_ viewer: ViewerController, didShow item: Item?) {
        inspector.update(item)
        updateChrome()
    }

    func viewerControllerWantsClose(_ viewer: ViewerController) {
        closeViewer(animated: true)
    }

    func viewerController(_ viewer: ViewerController, open url: URL) {
        open(url)
    }

    func viewerController(_ viewer: ViewerController, slideshowDidChange running: Bool) {
        rootView.showsSortBar = running ? false : Preferences.showSortBar
        if !running, enteredFullScreenForSlideshow, window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
        }
    }
}

extension MainWindowController: SortBarDelegate {
    func sortBar(_ bar: SortBarView, send slot: Int, copy: Bool) {
        sort(to: slot, copy: copy)
    }

    func sortBar(_ bar: SortBarView, drop urls: [URL], on slot: Int, copy: Bool) {
        guard let folder = SortTargets.shared.folder(at: slot) else { return }
        if copy { operations.copy(urls, into: folder) } else { operations.move(urls, into: folder) }
        bar.flash(slot)
    }

    func sortBar(_ bar: SortBarView, choose slot: Int) {
        chooseTarget(slot)
    }
}

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let thumbnailSize = Self("thumbnailSize")
    static let sortOrder = Self("sortOrder")
    static let filter = Self("filter")
    static let slideshow = Self("slideshow")
    static let info = Self("info")
    static let search = Self("search")
}

extension MainWindowController: NSToolbarDelegate, NSSearchFieldDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .flexibleSpace, .thumbnailSize, .sortOrder, .filter, .slideshow, .info, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .back:
            let item = button(identifier, String(localized: "Back"), "chevron.left", #selector(goBack(_:)))
            item.isNavigational = true
            return item
        case .thumbnailSize:
            let slider = NSSlider(value: Double(browser.tileSide), minValue: Double(BrowserController.tileRange.lowerBound),
                                  maxValue: Double(BrowserController.tileRange.upperBound), target: self, action: #selector(thumbnailSliderChanged(_:)))
            slider.controlSize = .small
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
            sizeSlider = slider
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = slider
            item.label = String(localized: "Thumbnail Size")
            item.toolTip = String(localized: "Thumbnail size (or pinch the grid)")
            return item
        case .sortOrder:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
            item.label = String(localized: "Sort")
            item.toolTip = String(localized: "Sort order")
            item.menu = MainMenu.sortByMenu()
            item.showsIndicator = false
            return item
        case .filter:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
            item.label = String(localized: "Filter")
            item.toolTip = String(localized: "Show only images, videos or a tag")
            item.menu = MainMenu.filterMenu()
            item.showsIndicator = false
            return item
        case .slideshow:
            return button(identifier, String(localized: "Slideshow"), "play", #selector(toggleSlideshow(_:)))
        case .info:
            return button(identifier, String(localized: "Info"), "info.circle", #selector(toggleInspector(_:)))
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.delegate = self
            item.searchField.placeholderString = String(localized: "Search names")
            item.preferredWidthForSearchField = 180
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.action = action
        item.target = self
        item.isBordered = true
        return item
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        model.searchText = field.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        model.searchText = ""
        browser.focus()
    }
}

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

/// Grid and viewer stacked in the same place, sort bar along the bottom.
final class RootView: NSView {
    var browserView: NSView? { didSet { install(browserView, below: viewerView) } }
    var viewerView: NSView? { didSet { install(viewerView, below: emptyState) } }
    var emptyState: NSView? { didSet { install(emptyState, below: nil) } }
    var sortBar: NSView? { didSet { install(sortBar, below: nil) } }
    var showsSortBar = true { didSet { needsLayout = true } }

    private func install(_ view: NSView?, below other: NSView?) {
        guard let view else { return }
        if let other, other.superview === self {
            addSubview(view, positioned: .below, relativeTo: other)
        } else {
            addSubview(view)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let barHeight: CGFloat = showsSortBar ? 38 : 0
        sortBar?.isHidden = !showsSortBar
        sortBar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let content = NSRect(x: 0, y: barHeight, width: bounds.width, height: bounds.height - barHeight)
        for view in [browserView, viewerView, emptyState] { view?.frame = content }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
