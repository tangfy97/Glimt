import AppKit
import UniformTypeIdentifiers
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let lastOpenedKey = "LastOpenedPath"

    private var viewer: ViewerWindowController?
    private var benchmark: Benchmark?
    private var openedByEvent = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewer = ensureViewer()
        viewer.showWindow(nil)

        if !openedByEvent, let url = launchURL() {
            viewer.open(url)
        }
        let launchMs = ProcessMetrics.millisecondsSinceProcessStart()
        Log.app.info("Window up \(launchMs, format: .fixed(precision: 1)) ms after process start")

        benchmark = Benchmark(viewer: viewer, launchMs: launchMs)
        benchmark?.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedByEvent = true
        let viewer = ensureViewer()
        viewer.showWindow(nil)
        viewer.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let viewer = ensureViewer()
        viewer.showWindow(nil)
        guard let window = viewer.window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .folder]
        panel.message = String(localized: "Choose a folder, or an image inside one.")
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            viewer.open(url)
        }
    }

    private func ensureViewer() -> ViewerWindowController {
        if let viewer { return viewer }
        let viewer = ViewerWindowController()
        viewer.onOpenedURL = { url in
            UserDefaults.standard.set(url.path, forKey: Self.lastOpenedKey)
        }
        self.viewer = viewer
        return viewer
    }

    /// A path passed on the command line wins; otherwise reopen where the user left off.
    private func launchURL() -> URL? {
        let fileManager = FileManager.default
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            if fileManager.fileExists(atPath: argument) { return URL(fileURLWithPath: argument) }
        }
        if let path = UserDefaults.standard.string(forKey: Self.lastOpenedKey), fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

enum Log {
    static let app = Logger(subsystem: "com.feiyangtang.Glimt", category: "app")
}
