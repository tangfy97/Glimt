import AppKit
import Carbon.HIToolbox

/// Menu and toolbar commands, and their validation.
extension MainWindowController {
    // MARK: - File commands

    /// The files a command acts on: the image in the viewer, or the grid selection.
    func targetURLs(includingFolders: Bool = false) -> [URL] {
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

    func chooseTarget(_ slot: Int) {
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
            showAlert(error.localizedDescription)
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
        let field = NSTextField(string: model.folder.map { FolderAccess.abbreviated($0.path) } ?? "~/")
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.placeholderString = "~/Pictures"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let path = FolderAccess.expanded(field.stringValue.trimmingCharacters(in: .whitespaces))
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    self?.showAlert(String(localized: "There is no folder at “\(path)”."))
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

    @objc func thumbnailSliderChanged(_ sender: NSSlider) {
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

    func folderColumnsChanged() {
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

    func preferencesChanged() {
        browser.applyPreferences()
        if rootView.showsSortBar != Preferences.showSortBar && !viewer.isSlideshowRunning {
            rootView.showsSortBar = Preferences.showSortBar
        }
        viewer.view.needsLayout = true
    }

    func showAlert(_ message: String) {
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
}
