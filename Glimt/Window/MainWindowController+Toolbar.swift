import AppKit

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
