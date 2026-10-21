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
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Help"))
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
        menu.addItem(withTitle: String(localized: "Open…"), action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.addItem(withTitle: String(localized: "Clear Menu"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Open Recent"), action: nil, keyEquivalent: "").submenu = recent
        menu.addItem(item(String(localized: "Open with Default App"), #selector(Main.openWithDefaultApp(_:)), "o", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Show in Finder"), #selector(Main.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(item(String(localized: "Rename…"), #selector(Main.renameItem(_:)), "r", [.command, .shift]))
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
            let move = moveTo.addItem(withTitle: "", action: #selector(Main.sortToTarget(_:)), keyEquivalent: "")
            move.tag = slot
            let copy = copyTo.addItem(withTitle: "", action: #selector(Main.sortToTarget(_:)), keyEquivalent: "")
            copy.tag = 10 + slot
        }
        menu.addItem(withTitle: String(localized: "Move To"), action: nil, keyEquivalent: "").submenu = moveTo
        menu.addItem(withTitle: String(localized: "Copy To"), action: nil, keyEquivalent: "").submenu = copyTo
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Rotate Left"), action: #selector(Main.rotateLeft(_:)), keyEquivalent: "l")
        menu.addItem(withTitle: String(localized: "Rotate Right"), action: #selector(Main.rotateRight(_:)), keyEquivalent: "r")
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
        menu.addItem(withTitle: String(localized: "Sort By"), action: nil, keyEquivalent: "").submenu = sortByMenu()
        menu.addItem(withTitle: String(localized: "Show"), action: nil, keyEquivalent: "").submenu = filterMenu()
        menu.addItem(withTitle: String(localized: "Show File Names"), action: #selector(Main.toggleFileNames(_:)), keyEquivalent: "")
        menu.addItem(item(String(localized: "Show Sort Bar"), #selector(Main.toggleSortBar(_:)), "b", [.command, .option]))
        menu.addItem(withTitle: String(localized: "Show Info"), action: #selector(Main.toggleInspector(_:)), keyEquivalent: "i")
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Start Slideshow"), #selector(Main.toggleSlideshow(_:)), "p", [.command, .option]))
        menu.addItem(item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    static func sortByMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Sort By"))
        let names = [String(localized: "Name"), String(localized: "Date Modified"), String(localized: "Date Created"), String(localized: "Size")]
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
        // Arrow keys, Space, Home and End are handled by the views (so the grid keeps its
        // own arrow navigation); these items are for discoverability and the mouse.
        menu.addItem(withTitle: String(localized: "Next Image"), action: #selector(Main.nextImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Previous Image"), action: #selector(Main.previousImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "First Image"), action: #selector(Main.firstImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Last Image"), action: #selector(Main.lastImage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Enclosing Folder"), #selector(Main.openEnclosingFolder(_:)), key(NSUpArrowFunctionKey), [.command]))
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

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }
}
