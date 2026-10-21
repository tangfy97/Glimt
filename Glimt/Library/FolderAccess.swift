import AppKit

extension Notification.Name {
    /// The user allowed Glimt into another folder; listings that came back empty may not be.
    static let folderAccessDidChange = Notification.Name("GlimtFolderAccessDidChange")
}

/// The App Store build runs in the App Sandbox, where Glimt may only read folders the user has
/// chosen (plus Pictures, Movies and Downloads, which its entitlements name). Every folder the
/// user hands over, through an open panel, a drop or Finder, is kept as a security-scoped
/// bookmark so the permission survives relaunching. Outside the sandbox every check passes and
/// nothing is stored.
@MainActor
enum FolderAccess {
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The user's real home folder. Inside the sandbox `homeDirectoryForCurrentUser` is the
    /// app's container, which is not what anyone means by Home.
    nonisolated static let home: URL = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }()

    /// `path` with the home folder written as ~, for display.
    nonisolated static func abbreviated(_ path: String) -> String {
        let home = self.home.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The reverse of `abbreviated`, for paths the user types.
    nonisolated static func expanded(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? home.path + path.dropFirst() : path
    }

    private static let key = "FolderBookmarks"
    /// Granted folders and files by path, each already being accessed.
    private static var granted: [String: URL] = [:]

    /// Resolves the stored bookmarks and starts using them. Call once at launch.
    static func restore() {
        guard isSandboxed else { return }
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        var kept: [String: Data] = [:]
        for data in stored.values {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
                  url.startAccessingSecurityScopedResource() else { continue }
            granted[url.path] = url
            kept[url.path] = isStale ? (try? url.bookmarkData(options: .withSecurityScope)) ?? data : data
        }
        UserDefaults.standard.set(kept, forKey: key)
    }

    /// Keeps the permission for `url` if Glimt has it now but only for this session, as it does
    /// for a folder just chosen in an open panel, dropped on a window or opened from Finder.
    static func remember(_ url: URL) {
        guard isSandboxed, !isCovered(url),
              let data = try? url.bookmarkData(options: .withSecurityScope),
              url.startAccessingSecurityScopedResource() else { return }
        granted[url.path] = url
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        stored[url.path] = data
        UserDefaults.standard.set(stored, forKey: key)
    }

    /// Whether Glimt may list `folder`. Asks the file system rather than the bookmarks, since
    /// the entitlements and the current session's permissions count too.
    static func canRead(_ folder: URL) -> Bool {
        guard isSandboxed else { return true }
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// Asks the user to allow `folder` (or any folder that contains it) with an open panel
    /// already showing it. Returns whether Glimt can read it afterwards.
    static func request(_ folder: URL, attachedTo window: NSWindow?) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Allow Access")
        panel.message = String(localized: "Choose this folder, or one that contains it. Allowing your home folder lets Glimt open every folder inside it.")
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return false }
        remember(url)
        NotificationCenter.default.post(name: .folderAccessDidChange, object: nil)
        return canRead(folder)
    }

    /// Folders the entitlements open without asking.
    private static let entitled = ["Pictures", "Movies", "Downloads"].map { home.appendingPathComponent($0).path }

    private static func isCovered(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return (entitled + granted.keys).contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }
}
