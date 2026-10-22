import Foundation

/// The one list of keyboard shortcuts, shown in the viewer's `?` sheet and in Settings.
enum Shortcuts {
    struct Group: Identifiable {
        let title: String
        let entries: [(keys: String, action: String)]
        var id: String { title }
    }

    static var groups: [Group] {
        [
            Group(title: String(localized: "Browse"), entries: [
                ("← →  Space", String(localized: "Previous / next")),
                ("Page Up  Page Down", String(localized: "Back / forward 10")),
                ("Home  End", String(localized: "First / last")),
                ("Return", String(localized: "Open in viewer")),
                ("Esc", String(localized: "Back to the grid")),
                ("⌘[  ⌘]", String(localized: "Back / forward through folders")),
                ("⌘↑", String(localized: "Enclosing folder")),
                ("⌥⌘S", String(localized: "Show or hide folder columns")),
                ("Tab", String(localized: "Between folder columns and pictures")),
                ("⌘F", String(localized: "Search names")),
            ]),
            Group(title: String(localized: "Sort into folders"), entries: [
                ("1 – 9", String(localized: "Move to sort folder")),
                ("⇧1 – ⇧9", String(localized: "Copy to sort folder")),
                ("⌥1 – ⌥9", String(localized: "Choose the folder for a key")),
                ("⌘⌫", String(localized: "Move to Trash")),
                ("⌃1 – ⌃7", String(localized: "Toggle a Finder tag")),
                ("⌘Z", String(localized: "Undo")),
            ]),
            Group(title: String(localized: "Look"), entries: [
                ("Z", String(localized: "Hold for 100%, tap to stay")),
                ("⌘=  ⌘−", String(localized: "Zoom in / out")),
                ("⌘0  ⌘9", String(localized: "Actual size / fit")),
                ("⌘L  ⌘R", String(localized: "Rotate left / right")),
                ("I", String(localized: "Show file info")),
                ("F", String(localized: "Full screen")),
                ("⌥⌘P", String(localized: "Slideshow")),
                ("[  ]", String(localized: "Slideshow slower / faster")),
            ]),
        ]
    }
}
