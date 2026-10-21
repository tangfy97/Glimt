import AppKit

@MainActor
enum MainMenu {
    private typealias Main = MainWindowController

    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(imageMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(slideshowMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Help"))
        help.addItem(item(String(localized: "Keyboard Shortcuts"), #selector(Main.showShortcuts(_:)), "/", [.command]))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Glimt")
        menu.addItem(withTitle: String(localized: "About Glimt"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        menu.addItem(withTitle: String(localized: "Services"), action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Hide Glimt"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Glimt"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(withTitle: String(localized: "New Window"), action: #selector(Main.newWindow(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: String(localized: "New Tab"), action: #selector(Main.newTab(_:)), keyEquivalent: "t")
        menu.addItem(withTitle: String(localized: "Open…"), action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.delegate = DynamicMenus.shared
        recent.identifier = DynamicMenus.recent
        menu.addItem(withTitle: String(localized: "Open Recent"), action: nil, keyEquivalent: "").submenu = recent
        let openWith = NSMenu(title: String(localized: "Open With"))
        openWith.delegate = DynamicMenus.shared
        openWith.identifier = DynamicMenus.openWith
        menu.addItem(withTitle: String(localized: "Open With"), action: nil, keyEquivalent: "").submenu = openWith
        menu.addItem(item(String(localized: "Open with Default App"), #selector(Main.openWithDefaultApp(_:)), "o", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Show in Finder"), #selector(Main.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(withTitle: String(localized: "Share…"), action: #selector(Main.share(_:)), keyEquivalent: "")
        menu.addItem(item(String(localized: "Rename…"), #selector(Main.renameItem(_:)), "r", [.command, .shift]))
        menu.addItem(item(String(localized: "Set as Desktop Picture"), #selector(Main.setDesktopPicture(_:)), "d", [.command, .option]))
        menu.addItem(item(String(localized: "Move to Trash"), #selector(Main.moveToTrash(_:)), "\u{8}", [.command]))
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(item(String(localized: "Select None"), #selector(Main.selectNone(_:)), "a", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Find…"), action: #selector(Main.focusSearch(_:)), keyEquivalent: "f")
        return menu
    }

    private static func imageMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Image"))
        let moveTo = NSMenu(title: String(localized: "Move To"))
        let copyTo = NSMenu(title: String(localized: "Copy To"))
        for slot in 0..<SortTargets.count {
            // The window handles the digit keys itself (⇧ copies), so that typing digits into the
            // search field never sorts a file; the titles carry the number instead.
            moveTo.addItem(withTitle: "", action: #selector(Main.sortToTarget(_:)), keyEquivalent: "").tag = slot
            copyTo.addItem(withTitle: "", action: #selector(Main.sortToTarget(_:)), keyEquivalent: "").tag = 10 + slot
        }
        for (menu, tag) in [(moveTo, 0), (copyTo, 1)] {
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Other Folder…"), action: #selector(Main.moveToOtherFolder(_:)), keyEquivalent: "").tag = tag
        }
        menu.addItem(withTitle: String(localized: "Move To"), action: nil, keyEquivalent: "").submenu = moveTo
        menu.addItem(withTitle: String(localized: "Copy To"), action: nil, keyEquivalent: "").submenu = copyTo
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Rotate Left"), action: #selector(Main.rotateLeft(_:)), keyEquivalent: "l")
        menu.addItem(withTitle: String(localized: "Rotate Right"), action: #selector(Main.rotateRight(_:)), keyEquivalent: "r")
        menu.addItem(withTitle: String(localized: "Rotate 180°"), action: #selector(Main.rotate180(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Flip Horizontal"), action: #selector(Main.flipHorizontal(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Flip Vertical"), action: #selector(Main.flipVertical(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(tagsItem(withKeys: true))
        return menu
    }

    static func tagsItem(withKeys: Bool = false) -> NSMenuItem {
        let tags = NSMenu(title: String(localized: "Tags"))
        for (index, tag) in FinderTags.all.enumerated() {
            let item = tags.addItem(withTitle: tag.name, action: #selector(Main.toggleTag(_:)), keyEquivalent: withKeys ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = .control
            item.tag = index
            item.image = dot(tag.color)
        }
        tags.addItem(.separator())
        let clear = tags.addItem(withTitle: String(localized: "Clear Tags"), action: #selector(Main.clearTags(_:)), keyEquivalent: withKeys ? "0" : "")
        clear.keyEquivalentModifierMask = .control
        let item = NSMenuItem(title: String(localized: "Tags"), action: nil, keyEquivalent: "")
        item.submenu = tags
        return item
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(withTitle: String(localized: "Open in Viewer"), action: #selector(Main.showViewerOrGrid(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Zoom In"), action: #selector(Main.zoomIn(_:)), keyEquivalent: "=")
        menu.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(Main.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: String(localized: "Actual Size"), action: #selector(Main.zoomToActualSize(_:)), keyEquivalent: "0")
        menu.addItem(withTitle: String(localized: "Zoom to Fit"), action: #selector(Main.zoomToFit(_:)), keyEquivalent: "9")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Enlarge Small Images"), action: #selector(Main.toggleUpscale(_:)), keyEquivalent: "e")
        menu.addItem(item(String(localized: "Open Large Images at Actual Size"), #selector(Main.toggleActualSize(_:)), "e", [.command, .shift]))
        menu.addItem(item(String(localized: "Keep Zoom When Paging"), #selector(Main.toggleKeepZoom(_:)), "k", [.command, .option]))
        menu.addItem(withTitle: String(localized: "File Info on Image"), action: #selector(Main.toggleInfoOverlay(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Sort By"), action: nil, keyEquivalent: "").submenu = sortByMenu()
        menu.addItem(withTitle: String(localized: "Show"), action: nil, keyEquivalent: "").submenu = filterMenu()
        menu.addItem(item(String(localized: "Show Folder Columns"), #selector(Main.toggleFolderColumns(_:)), "s", [.command, .option]))
        menu.addItem(item(String(localized: "Include Subfolders"), #selector(Main.toggleSubfolders(_:)), "f", [.command, .shift]))
        menu.addItem(withTitle: String(localized: "Show File Names"), action: #selector(Main.toggleFileNames(_:)), keyEquivalent: "")
        menu.addItem(item(String(localized: "Show Sort Bar"), #selector(Main.toggleSortBar(_:)), "b", [.command, .option]))
        menu.addItem(withTitle: String(localized: "Show Info"), action: #selector(Main.toggleInspector(_:)), keyEquivalent: "i")
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func slideshowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Slideshow"))
        let start = item(String(localized: "Start Slideshow"), #selector(Main.toggleSlideshow(_:)), "p", [.command, .option])
        start.tag = 0
        menu.addItem(start)
        menu.addItem(withTitle: String(localized: "Start Slideshow in Window"), action: #selector(Main.toggleSlideshow(_:)), keyEquivalent: "").tag = 1
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Loop"), action: #selector(Main.toggleLoop(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Shuffle"), action: #selector(Main.toggleShuffle(_:)), keyEquivalent: "")
        return menu
    }

    static func sortByMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Sort By"))
        let names = [String(localized: "Name"), String(localized: "Date Modified"), String(localized: "Date Created"),
                     String(localized: "Date Added"), String(localized: "Kind"), String(localized: "Size")]
        for (index, name) in names.enumerated() {
            menu.addItem(withTitle: name, action: #selector(Main.setSortKey(_:)), keyEquivalent: "").tag = index
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Ascending"), action: #selector(Main.setSortAscending(_:)), keyEquivalent: "").tag = 0
        menu.addItem(withTitle: String(localized: "Descending"), action: #selector(Main.setSortAscending(_:)), keyEquivalent: "").tag = 1
        return menu
    }

    static func filterMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Show"))
        let kinds = [String(localized: "Images and Videos"), String(localized: "Images Only"), String(localized: "Videos Only")]
        for (index, name) in kinds.enumerated() {
            menu.addItem(withTitle: name, action: #selector(Main.setKindFilter(_:)), keyEquivalent: "").tag = index
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Any Tag"), action: #selector(Main.setTagFilter(_:)), keyEquivalent: "").tag = -1
        for (index, tag) in FinderTags.all.enumerated() {
            let item = menu.addItem(withTitle: tag.name, action: #selector(Main.setTagFilter(_:)), keyEquivalent: "")
            item.tag = index
            item.image = dot(tag.color)
        }
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Go"))
        // Arrow keys, Space, Page Up/Down, Home and End are handled by the views (so the grid
        // keeps its own arrow navigation); these items are for discoverability and the mouse.
        menu.addItem(withTitle: String(localized: "Next Image"), action: #selector(Main.nextImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Previous Image"), action: #selector(Main.previousImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "First Image"), action: #selector(Main.firstImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Last Image"), action: #selector(Main.lastImage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Back"), action: #selector(Main.goBack(_:)), keyEquivalent: "[")
        menu.addItem(withTitle: String(localized: "Forward"), action: #selector(Main.goForward(_:)), keyEquivalent: "]")
        menu.addItem(item(String(localized: "Enclosing Folder"), #selector(Main.openEnclosingFolder(_:)), key(NSUpArrowFunctionKey), [.command]))
        menu.addItem(item(String(localized: "Go to Folder…"), #selector(Main.goToFolder(_:)), "g", [.command, .shift]))
        menu.addItem(.separator())
        let home = FileManager.default.homeDirectoryForCurrentUser
        let places: [(String, URL, String, NSEvent.ModifierFlags)] = [
            (String(localized: "Home"), home, "h", [.command, .shift]),
            (String(localized: "Desktop"), home.appendingPathComponent("Desktop"), "d", [.command, .shift]),
            (String(localized: "Downloads"), home.appendingPathComponent("Downloads"), "l", [.command, .option]),
            (String(localized: "Pictures"), home.appendingPathComponent("Pictures"), "p", [.command, .shift]),
        ]
        for (title, url, key, modifiers) in places {
            let entry = item(title, #selector(Main.goToPlace(_:)), key, modifiers)
            entry.representedObject = url
            entry.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(entry)
        }
        let volumes = NSMenu(title: String(localized: "Volumes"))
        volumes.delegate = DynamicMenus.shared
        volumes.identifier = DynamicMenus.volumes
        menu.addItem(withTitle: String(localized: "Volumes"), action: nil, keyEquivalent: "").submenu = volumes
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ keyEquivalent: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt16(functionKey))!))
    }

    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }
}

/// Menus whose contents depend on the moment: Open With (the selected file's apps) and Volumes.
@MainActor
final class DynamicMenus: NSObject, NSMenuDelegate {
    static let shared = DynamicMenus()
    static let openWith = NSUserInterfaceItemIdentifier("openWith")
    static let volumes = NSUserInterfaceItemIdentifier("volumes")
    static let recent = NSUserInterfaceItemIdentifier("recent")

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.identifier {
        case Self.openWith:
            guard let controller = NSApp.keyWindow?.windowController as? MainWindowController else { return }
            for item in controller.openWithMenu().items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        case Self.recent:
            // AppKit only fills Open Recent itself for document-based apps.
            for url in Preferences.recentURLs {
                let item = menu.addItem(withTitle: FileManager.default.displayName(atPath: url.path), action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
                item.representedObject = url
                item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
                item.image = NSWorkspace.shared.icon(forFile: url.path)
                item.image?.size = NSSize(width: 16, height: 16)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: String(localized: "Clear Menu"), action: #selector(AppDelegate.clearRecents(_:)), keyEquivalent: "")
        case Self.volumes:
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
            for url in urls {
                let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
                let item = menu.addItem(withTitle: name, action: #selector(MainWindowController.goToPlace(_:)), keyEquivalent: "")
                item.representedObject = url
                item.image = NSWorkspace.shared.icon(forFile: url.path)
                item.image?.size = NSSize(width: 16, height: 16)
            }
        default:
            break
        }
    }
}
