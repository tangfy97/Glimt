import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Glimt")
        menu.addItem(withTitle: String(localized: "About Glimt"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        let servicesItem = menu.addItem(withTitle: String(localized: "Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
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
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(withTitle: String(localized: "Zoom In"), action: #selector(ViewerWindowController.zoomIn(_:)), keyEquivalent: "=")
        menu.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(ViewerWindowController.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: String(localized: "Actual Size"), action: #selector(ViewerWindowController.zoomToActualSize(_:)), keyEquivalent: "0")
        menu.addItem(withTitle: String(localized: "Zoom to Fit"), action: #selector(ViewerWindowController.zoomToFit(_:)), keyEquivalent: "9")
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Go"))
        // The viewer handles these keys itself (so ↑/↓ can pan when zoomed);
        // the menu exists for discoverability and mouse use.
        menu.addItem(item(String(localized: "Next Image"), #selector(ViewerWindowController.nextImage(_:)), key(NSRightArrowFunctionKey), []))
        menu.addItem(item(String(localized: "Previous Image"), #selector(ViewerWindowController.previousImage(_:)), key(NSLeftArrowFunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "First Image"), #selector(ViewerWindowController.firstImage(_:)), key(NSHomeFunctionKey), []))
        menu.addItem(item(String(localized: "Last Image"), #selector(ViewerWindowController.lastImage(_:)), key(NSEndFunctionKey), []))
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
}
