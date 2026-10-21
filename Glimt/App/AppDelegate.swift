import AppKit
import UniformTypeIdentifiers
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController?
    private var benchmark: Benchmark?
    private var selfTest: SelfTest?
    private var openedByEvent = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = ensureMain()
        main.showWindow(nil)
        let launchMs = ProcessMetrics.millisecondsSinceProcessStart()
        Log.app.info("Window up \(launchMs, format: .fixed(precision: 1)) ms after process start")

        if let test = SelfTest(window: main) {
            selfTest = test
            test.start()
            return
        }
        benchmark = Benchmark(window: main, launchMs: launchMs)
        benchmark?.start()

        if !openedByEvent, let url = launchURL() {
            main.open(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedByEvent = true
        let main = ensureMain()
        main.showWindow(nil)
        main.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let main = ensureMain()
        main.showWindow(nil)
        guard let window = main.window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.message = String(localized: "Choose a folder, or an image inside one.")
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            main.open(url)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    private func ensureMain() -> MainWindowController {
        if let main { return main }
        let main = MainWindowController()
        main.onOpenedURL = { url in Preferences.lastOpenedPath = url.path }
        self.main = main
        return main
    }

    /// A path passed on the command line wins; otherwise reopen where the user left off.
    private func launchURL() -> URL? {
        let fileManager = FileManager.default
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            if fileManager.fileExists(atPath: argument) { return URL(fileURLWithPath: argument) }
        }
        if let path = Preferences.lastOpenedPath, fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

enum Log {
    static let app = Logger(subsystem: "com.feiyangtang.Glimt", category: "app")
}
