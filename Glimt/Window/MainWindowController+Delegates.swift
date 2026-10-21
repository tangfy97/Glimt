import AppKit

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
