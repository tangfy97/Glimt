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

    private let rootView = RootView()
    private let sortBar = SortBarView()
    private let emptyState = PlaceholderView()
    private(set) var mode = Mode.browser
    private var isTransitioning = false
    /// Folders visited in this window, for Back and Forward (as in Finder; ⌘↑ is "up").
    private var history: [URL] = []
    private var historyIndex = -1
    private var isNavigatingHistory = false
    private var enteredFullScreenForSlideshow = false
    private var searchItem: NSSearchToolbarItem?
    private var sizeSlider: NSSlider?

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

        sizeSlider?.target = self
        sizeSlider?.action = #selector(thumbnailSliderChanged(_:))
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

        let toolbar = NSToolbar(identifier: "Main.v2")
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

    private func modelChanged(_ change: FolderModel.Change) {
        browser.reload()
        if !model.isLoading, let folder = model.folder, !model.includesSubfolders {
            folderColumns.reveal(folder, subfolders: model.subfolderURLs)
        }
        if model.isLoading {
            emptyState.show(.loading(folder: model.folder?.lastPathComponent ?? ""))
        } else if model.folder == nil {
            emptyState.show(.welcome)
        } else if (model.folders.isEmpty || !browser.showsFolderTiles) && model.media.isEmpty {
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

    private func updateChrome() {
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
            let name = folder.lastPathComponent
            viewer.view.flashMessage(copy ? String(localized: "Copied to \(name)") : String(localized: "Moved to \(name)"))
        }
    }

    /// Move To / Copy To ▸ Other Folder…: any folder, chosen each time.
    @objc func moveToOtherFolder(_ sender: NSMenuItem) {
        let urls = targetURLs()
        guard !urls.isEmpty, let window else { return NSSound.beep() }
        let copy = sender.tag == 1
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = copy ? String(localized: "Copy") : String(localized: "Move")
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let folder = panel.url else { return }
            if copy { operations.copy(urls, into: folder) } else { operations.move(urls, into: folder) }
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
        if mode == .viewer { viewer.view.flashMessage(String(localized: "Moved to the Trash")) }
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

    @objc func rotateLeft(_ sender: Any?) { transform(.rotateLeft) }
    @objc func rotateRight(_ sender: Any?) { transform(.rotateRight) }
    @objc func rotate180(_ sender: Any?) { transform(.rotate180) }
    @objc func flipHorizontal(_ sender: Any?) { transform(.flipHorizontal) }
    @objc func flipVertical(_ sender: Any?) { transform(.flipVertical) }

    private func transform(_ transform: ImageRotator.Transform) {
        let urls = targetURLs().filter { model.item(for: $0)?.kind == .image }
        guard !urls.isEmpty else { return NSSound.beep() }
        operations.transform(urls, transform)
    }

    @objc func setDesktopPicture(_ sender: Any?) {
        guard let url = targetURLs().first(where: { model.item(for: $0)?.kind == .image }),
              let screen = window?.screen ?? NSScreen.main else { return NSSound.beep() }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            if mode == .viewer { viewer.view.flashMessage(String(localized: "Set as desktop picture")) }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc func share(_ sender: Any?) {
        let urls = targetURLs()
        guard !urls.isEmpty, let contentView = window?.contentView, let window else { return NSSound.beep() }
        let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: urls).show(relativeTo: NSRect(origin: point, size: .zero), of: contentView, preferredEdge: .minY)
    }

    /// File ▸ Open With: the apps that can open the first target, default first.
    func openWithMenu() -> NSMenu {
        let menu = NSMenu()
        guard let url = targetURLs().first else { return menu }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        for app in apps.prefix(20) {
            var title = FileManager.default.displayName(atPath: app.path)
            if app == preferred { title += String(localized: " (default)") }
            let item = menu.addItem(withTitle: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if app == preferred, apps.count > 1 { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(targetURLs(), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        let tags = FinderTags.all
        guard tags.indices.contains(sender.tag) else { return }
        let urls = targetURLs(includingFolders: true)
        guard !urls.isEmpty else { return NSSound.beep() }
        operations.toggleTag(tags[sender.tag].name, on: urls)
        if mode == .viewer, let item = viewer.currentItem {
            let has = item.tags.contains(tags[sender.tag].name)
            let name = tags[sender.tag].name
            viewer.view.flashMessage(has ? String(localized: "Added tag \(name)") : String(localized: "Removed tag \(name)"))
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

    @objc func selectNone(_ sender: Any?) {
        if mode == .browser { browser.collectionView.deselectAll(nil) }
    }

    @objc func openWithDefaultApp(_ sender: Any?) {
        for url in targetURLs(includingFolders: false) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Navigation commands

    /// In the viewer: back to the grid. In the grid: the previously visited folder.
    @objc func goBack(_ sender: Any?) {
        if mode == .viewer {
            closeViewer(animated: true)
        } else if historyIndex > 0 {
            visitHistory(historyIndex - 1)
        }
    }

    @objc func goForward(_ sender: Any?) {
        if mode == .browser, historyIndex + 1 < history.count { visitHistory(historyIndex + 1) }
    }

    private func visitHistory(_ index: Int) {
        historyIndex = index
        isNavigatingHistory = true
        open(history[index])
        isNavigatingHistory = false
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

    /// Go ▸ Home / Desktop / Pictures / volumes: `representedObject` is the folder.
    @objc func goToPlace(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Go to the folder")
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: (model.folder?.path as NSString?)?.abbreviatingWithTildeInPath ?? "~/")
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.placeholderString = "~/Pictures"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let path = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    self?.presentError(String(localized: "There is no folder at “\(path)”."))
                    return
                }
                self?.open(URL(fileURLWithPath: path))
            }
        }
    }

    @objc func newWindow(_ sender: Any?) { onNewWindow?(self, false) }
    @objc func newTab(_ sender: Any?) { onNewWindow?(self, true) }

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

    @objc func toggleFolderColumns(_ sender: Any?) {
        rootView.showsFolderColumns.toggle()
        folderColumnsChanged()
    }

    private func folderColumnsChanged() {
        Preferences.showsFolderColumns = rootView.showsFolderColumns
        Preferences.folderColumnsHeight = Double(rootView.folderColumnsHeight)
        browser.showsFolderTiles = !rootView.showsFolderColumns
        if rootView.showsFolderColumns, let folder = model.folder {
            folderColumns.reveal(folder, subfolders: model.subfolderURLs)
        }
        modelChanged(.reloaded)
    }

    @objc func toggleSubfolders(_ sender: Any?) {
        if mode == .viewer { closeViewer(animated: false) }
        model.includesSubfolders.toggle()
    }

    @objc func toggleUpscale(_ sender: Any?) {
        Preferences.upscaleSmallImages.toggle()
        viewer.view.needsLayout = true
        if mode == .viewer { viewer.zoomToFit() }
    }

    @objc func toggleActualSize(_ sender: Any?) {
        Preferences.showsLargeImagesAtActualSize.toggle()
        if mode == .viewer { viewer.reloadCurrent() }
    }

    @objc func toggleKeepZoom(_ sender: Any?) {
        Preferences.keepsZoomWhenPaging.toggle()
    }

    @objc func toggleInfoOverlay(_ sender: Any?) {
        viewer.cycleInfo()
    }

    @objc func toggleLoop(_ sender: Any?) { Preferences.slideshowLoops.toggle() }
    @objc func toggleShuffle(_ sender: Any?) { Preferences.slideshowShuffles.toggle() }

    @objc func showShortcuts(_ sender: Any?) {
        if mode == .viewer {
            viewer.view.toggleShortcuts()
        } else {
            ShortcutsPanel.shared.toggle()
        }
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

    /// Phoenix Slides' rules: nothing selected plays everything from the start, one image plays
    /// everything from there, several play just those. ⌥ (or the menu item) stays in the window.
    @objc func toggleSlideshow(_ sender: Any?) {
        if viewer.isSlideshowRunning {
            viewer.stopSlideshow()
            return
        }
        guard !model.media.isEmpty else { return NSSound.beep() }
        var selection: [URL]?
        if mode == .browser {
            let selected = browser.selectedMediaIndices
            selection = selected.count > 1 ? selected.map { model.media[$0].url } : nil
            openViewer(at: selected.first ?? 0, animated: false)
        }
        let inWindow = (sender as? NSMenuItem)?.tag == 1 || NSEvent.modifierFlags.contains(.option)
        if !inWindow, window?.styleMask.contains(.fullScreen) == false {
            enteredFullScreenForSlideshow = true
            window?.toggleFullScreen(nil)
        }
        viewer.startSlideshow(only: selection)
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
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(rotate180(_:)),
             #selector(flipHorizontal(_:)), #selector(flipVertical(_:)), #selector(setDesktopPicture(_:)):
            return targetURLs().contains { model.item(for: $0)?.kind == .image }
        case #selector(moveToOtherFolder(_:)), #selector(share(_:)):
            return !targetURLs().isEmpty
        case #selector(selectNone(_:)):
            return mode == .browser && !browser.collectionView.selectionIndexPaths.isEmpty
        case #selector(toggleFolderColumns(_:)):
            item.title = rootView.showsFolderColumns ? String(localized: "Hide Folder Columns") : String(localized: "Show Folder Columns")
            return mode == .browser
        case #selector(toggleSubfolders(_:)):
            item.state = model.includesSubfolders ? .on : .off
            return model.folder != nil
        case #selector(toggleUpscale(_:)):
            item.state = Preferences.upscaleSmallImages ? .on : .off
            return true
        case #selector(toggleActualSize(_:)):
            item.state = Preferences.showsLargeImagesAtActualSize ? .on : .off
            return true
        case #selector(toggleKeepZoom(_:)):
            item.state = Preferences.keepsZoomWhenPaging ? .on : .off
            return true
        case #selector(toggleLoop(_:)):
            item.state = Preferences.slideshowLoops ? .on : .off
            return true
        case #selector(toggleShuffle(_:)):
            item.state = Preferences.slideshowShuffles ? .on : .off
            return true
        case #selector(toggleInfoOverlay(_:)):
            return mode == .viewer
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
            if item.tag == 0 {
                item.title = viewer.isSlideshowRunning ? String(localized: "Stop Slideshow") : String(localized: "Start Slideshow")
            }
            return !model.media.isEmpty && (item.tag == 0 || !viewer.isSlideshowRunning)
        case #selector(goBack(_:)):
            return mode == .viewer || historyIndex > 0
        case #selector(goForward(_:)):
            return mode == .browser && historyIndex + 1 < history.count
        default:
            return true
        }
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
        if hasMedia {
            menu.addItem(withTitle: String(localized: "Open With"), action: nil, keyEquivalent: "").submenu = openWithMenu()
        }
        menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(revealInFinder(_:)), keyEquivalent: "")
        if hasMedia {
            menu.addItem(withTitle: String(localized: "Share…"), action: #selector(share(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        if hasMedia {
            let sortMenu = NSMenu()
            for slot in 0..<SortTargets.count {
                let item = sortMenu.addItem(withTitle: "", action: #selector(sortToTarget(_:)), keyEquivalent: "")
                item.tag = slot
            }
            sortMenu.addItem(.separator())
            sortMenu.addItem(withTitle: String(localized: "Other Folder…"), action: #selector(moveToOtherFolder(_:)), keyEquivalent: "").tag = 0
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
    static let sortOrder = Self("sortOrder")
    static let filter = Self("filter")
    static let slideshow = Self("slideshow")
    static let info = Self("info")
    static let share = Self("share")
    static let search = Self("search")
}

extension MainWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        targetURLs()
    }
}

extension MainWindowController: NSToolbarDelegate, NSSearchFieldDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .flexibleSpace, .sortOrder, .filter, .share, .slideshow, .info, .search]
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
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Share")
            item.delegate = self
            return item
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
