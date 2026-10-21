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
    let folderColumns = FolderBrowserController()

    let rootView = RootView()
    let sortBar = SortBarView()
    let emptyState = PlaceholderView()
    private(set) var mode = Mode.browser
    var isTransitioning = false
    /// Folders visited in this window, for Back and Forward (as in Finder; ⌘↑ is "up").
    var history: [URL] = []
    var historyIndex = -1
    var isNavigatingHistory = false
    var enteredFullScreenForSlideshow = false
    var searchItem: NSSearchToolbarItem?
    var sizeSlider: NSSlider?

    var onOpenedURL: ((URL) -> Void)?
    var onClose: ((MainWindowController) -> Void)?
    /// ⌘N / ⌘T: asks the app for another window or tab.
    var onNewWindow: ((MainWindowController, _ asTab: Bool) -> Void)?
    /// Benchmark / self-test hook: fires after each folder load.
    var onFolderLoaded: (() -> Void)?

    init(restoresFrame: Bool = true) {
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Glimt"
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "Glimt"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        super.init(window: window)

        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleWindowKey(event) ?? false }
        if restoresFrame {
            if !window.setFrameUsingName("Main") { window.center() }
            window.setFrameAutosaveName("Main")
        }

        rootView.browserView = browser.scrollView
        rootView.viewerView = viewer.view
        rootView.sortBar = sortBar
        let slider = NSSlider(value: Double(browser.tileSide), minValue: Double(BrowserController.tileRange.lowerBound),
                              maxValue: Double(BrowserController.tileRange.upperBound), target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.toolTip = String(localized: "Thumbnail size (or pinch the grid)")
        slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        sizeSlider = slider
        sortBar.accessory = slider
        rootView.emptyState = emptyState
        rootView.showsSortBar = Preferences.showSortBar
        rootView.folderColumns = folderColumns.view
        rootView.divider = FolderBrowserDivider()
        rootView.showsFolderColumns = Preferences.showsFolderColumns
        rootView.folderColumnsHeight = CGFloat(Preferences.folderColumnsHeight)
        rootView.onFolderColumnsChanged = { [weak self] in self?.folderColumnsChanged() }
        browser.showsFolderTiles = !Preferences.showsFolderColumns
        folderColumns.onOpen = { [weak self] url in
            guard let self, url.standardizedFileURL.path != self.model.folder?.standardizedFileURL.path else { return }
            self.open(url)
        }
        viewer.view.isHidden = true
        emptyState.show(.welcome)
        emptyState.onOpen = { [weak self] url in self?.open(url) }
        emptyState.onAllowAccess = { [weak self] folder in
            guard let self else { return }
            Task { _ = await FolderAccess.request(folder, attachedTo: self.window) }
        }

        sizeSlider?.target = self
        sizeSlider?.action = #selector(thumbnailSliderChanged(_:))
        browser.delegate = self
        viewer.delegate = self
        sortBar.delegate = self
        operations.model = model
        operations.onError = { [weak self] message in self?.showAlert(message) }
        operations.onContentsChanged = { [weak self] url in
            self?.browser.reloadThumbnail(for: url)
            self?.viewer.invalidate(url)
            self?.inspector.refresh()
        }
        model.observe { [weak self] change in self?.modelChanged(change) }

        let toolbar = NSToolbar(identifier: "Main.v2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(folderAccessChanged), name: .folderAccessDidChange, object: nil)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Opening

    /// Opens a folder in the grid, or an image straight in the viewer with its folder behind it.
    func open(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        FolderAccess.remember(folder)
        onOpenedURL?(url)
        Preferences.noteRecent(url)
        if !isNavigatingHistory, history.indices.contains(historyIndex) ? history[historyIndex].standardizedFileURL != folder.standardizedFileURL : true {
            history = Array(history.prefix(historyIndex + 1)) + [folder]
            historyIndex = history.count - 1
        }
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

    func modelChanged(_ change: FolderModel.Change) {
        browser.reload()
        if !model.isLoading, let folder = model.folder, !model.includesSubfolders {
            folderColumns.reveal(folder, subfolders: model.subfolderURLs)
        }
        if model.isLoading {
            emptyState.show(.loading(folder: model.folder?.lastPathComponent ?? ""))
        } else if model.folder == nil {
            emptyState.show(.welcome)
        } else if (model.folders.isEmpty || !browser.showsFolderTiles) && model.media.isEmpty {
            if let folder = model.folder, !FolderAccess.canRead(folder) {
                emptyState.show(.needsAccess(folder: folder))
            } else {
                emptyState.show(model.isFiltered ? .noMatches : .noImages(folder: model.folder?.lastPathComponent ?? ""))
            }
        } else {
            emptyState.isHidden = true
        }
        if mode == .browser { inspector.update(browser.selectedItems.first) }
        updateChrome()
    }

    /// Reads the open folder again if it was the one waiting for permission.
    @objc private func folderAccessChanged() {
        guard let folder = model.folder, model.media.isEmpty, model.folders.isEmpty, FolderAccess.canRead(folder) else { return }
        Task { await model.load(folder) }
    }

    // MARK: - Mode switching

    func openViewer(at index: Int, animated: Bool) {
        guard model.media.indices.contains(index), !isTransitioning else { return }
        let item = model.media[index]
        let thumbnail = browser.thumbnail(for: item.url)
        let start = animated ? browser.imageFrame(forMedia: index, in: rootView) : nil
        mode = .viewer
        rootView.isViewerMode = true
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
        rootView.isViewerMode = false
        rootView.layoutSubtreeIfNeeded()
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
    private func runTransition(contents: Any, from start: NSRect, to end: NSRect, appearing: Bool, completion: @escaping @MainActor () -> Void) {
        guard let rootLayer = rootView.layer else { return completion() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Reduce Motion: a short cross-fade instead of the flight.
            isTransitioning = true
            viewer.view.alphaValue = appearing ? 0 : 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                viewer.view.animator().alphaValue = appearing ? 1 : 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.viewer.view.alphaValue = 1
                    completion()
                    self.isTransitioning = false
                }
            }
            return
        }
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

    func updateChrome() {
        guard let window else { return }
        switch mode {
        case .browser:
            window.title = model.folder?.lastPathComponent ?? "Glimt"
            if model.isLoading {
                window.subtitle = String(localized: "Loading…")
            } else if model.folder != nil {
                var parts = [String(localized: "\(model.media.count) items")]
                if model.isFiltered { parts.append(String(localized: "filtered")) }
                if model.includesSubfolders { parts.append(String(localized: "with subfolders")) }
                let selected = browser.selectedItems.filter(\.isMedia)
                if selected.count > 1 {
                    let bytes = Int64(selected.reduce(0) { $0 + $1.fileSize })
                    parts.append(String(localized: "\(selected.count) selected, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"))
                }
                window.subtitle = parts.joined(separator: "  ·  ")
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
        sizeSlider?.isHidden = mode != .browser
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

    @objc override func selectAll(_ sender: Any?) {
        if mode == .browser { browser.selectAll() }
    }

    // MARK: - Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        operations.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        viewer.deactivate()
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Only the top folder is watched; with subfolders included, catch up on return.
        if model.includesSubfolders { model.scheduleRefresh() }
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
