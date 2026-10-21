import AppKit
import Observation

/// UserDefaults-backed settings. The Settings window binds the same keys with @AppStorage.
enum Preferences {
    enum Key {
        static let lastOpenedPath = "LastOpenedPath"
        static let showFileNames = "ShowFileNames"
        static let thumbnailSize = "ThumbnailSize"
        static let sortKey = "SortKey"
        static let sortAscending = "SortAscending"
        static let upscaleSmallImages = "UpscaleSmallImages"
        static let slideshowInterval = "SlideshowInterval"
        static let slideshowLoops = "SlideshowLoops"
        static let numberKeysCopy = "NumberKeysCopy"
        static let showSortBar = "ShowSortBar"
        static let sortTargets = "SortTargets"
    }

    private static var defaults: UserDefaults { .standard }

    static func register() {
        defaults.register(defaults: [
            Key.showFileNames: true,
            Key.thumbnailSize: 168.0,
            Key.sortKey: FolderModel.SortKey.name.rawValue,
            Key.sortAscending: true,
            Key.upscaleSmallImages: false,
            Key.slideshowInterval: 4.0,
            Key.slideshowLoops: true,
            Key.numberKeysCopy: false,
            Key.showSortBar: true,
        ])
    }

    static var lastOpenedPath: String? {
        get { defaults.string(forKey: Key.lastOpenedPath) }
        set { defaults.set(newValue, forKey: Key.lastOpenedPath) }
    }
    static var showFileNames: Bool { defaults.bool(forKey: Key.showFileNames) }
    static var thumbnailSize: Double {
        get { defaults.double(forKey: Key.thumbnailSize) }
        set { defaults.set(newValue, forKey: Key.thumbnailSize) }
    }
    static var sortKey: FolderModel.SortKey {
        get { FolderModel.SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .name }
        set { defaults.set(newValue.rawValue, forKey: Key.sortKey) }
    }
    static var sortAscending: Bool {
        get { defaults.bool(forKey: Key.sortAscending) }
        set { defaults.set(newValue, forKey: Key.sortAscending) }
    }
    static var upscaleSmallImages: Bool { defaults.bool(forKey: Key.upscaleSmallImages) }
    static var slideshowInterval: Double { max(1, defaults.double(forKey: Key.slideshowInterval)) }
    static var slideshowLoops: Bool { defaults.bool(forKey: Key.slideshowLoops) }
    static var numberKeysCopy: Bool { defaults.bool(forKey: Key.numberKeysCopy) }
    static var showSortBar: Bool {
        get { defaults.bool(forKey: Key.showSortBar) }
        set { defaults.set(newValue, forKey: Key.showSortBar) }
    }
}

/// The nine destination folders behind the number keys.
@MainActor
@Observable
final class SortTargets {
    static let shared = SortTargets()
    static let count = 9

    private(set) var folders: [URL?]

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Preferences.Key.sortTargets) ?? []
        folders = (0..<Self.count).map { slot in
            guard slot < paths.count, !paths[slot].isEmpty else { return nil }
            return URL(fileURLWithPath: paths[slot], isDirectory: true)
        }
    }

    func folder(at slot: Int) -> URL? {
        folders.indices.contains(slot) ? folders[slot] : nil
    }

    func set(_ folder: URL?, at slot: Int) {
        guard folders.indices.contains(slot) else { return }
        folders[slot] = folder
        UserDefaults.standard.set(folders.map { $0?.path ?? "" }, forKey: Preferences.Key.sortTargets)
        NotificationCenter.default.post(name: .sortTargetsDidChange, object: self)
    }

    /// Asks for a folder for `slot` (creating one is allowed) and stores it.
    func choose(for slot: Int, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use Folder")
        panel.message = String(localized: "Choose the folder for key \(slot + 1).")
        if let current = folder(at: slot) { panel.directoryURL = current }
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        set(url, at: slot)
        return url
    }
}

/// Finder's seven colour tags, in Finder's menu order. Names come from the system so they
/// match the user's language and any renamed tags.
@MainActor
enum FinderTags {
    struct Tag {
        let name: String
        let color: NSColor
    }

    // Legacy label numbers: 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
    private static let menuOrder = [6, 7, 5, 2, 4, 3, 1]

    static var all: [Tag] {
        let names = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        return menuOrder.compactMap { label in
            guard label < names.count, label < colors.count else { return nil }
            return Tag(name: names[label], color: colors[label])
        }
    }

    static func color(for name: String) -> NSColor? {
        let names = NSWorkspace.shared.fileLabels
        guard let index = names.firstIndex(of: name), index > 0 else { return nil }
        return NSWorkspace.shared.fileLabelColors[index]
    }
}
