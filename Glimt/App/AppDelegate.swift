import AppKit
import UniformTypeIdentifiers
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [MainWindowController] = []
    private var benchmark: Benchmark?
    private var selfTest: SelfTest?
    private var snapshot: Snapshot?
    private var openedByEvent = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
        Preferences.applyAppearance()
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting unit tests: no windows, no restored folder.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let main = frontWindow()
        main.showWindow(nil)
        let launchMs = ProcessMetrics.millisecondsSinceProcessStart()
        Log.app.info("Window up \(launchMs, format: .fixed(precision: 1)) ms after process start")

        if let test = SelfTest(window: main) {
            selfTest = test
            test.start()
            return
        }
        if let snapshot = Snapshot(window: main) {
            self.snapshot = snapshot
            snapshot.start()
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
        let main = frontWindow()
        main.showWindow(nil)
        main.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { frontWindow().showWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let main = frontWindow()
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

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let main = frontWindow()
        main.showWindow(nil)
        main.open(url)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: AppInfo.aboutCredits])
    }

    @objc func openRepository(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.Link.repository) }
    @objc func reportProblem(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.Link.issues) }
    @objc func openStudio(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.Link.studio) }

    @objc func clearRecents(_ sender: Any?) {
        Preferences.clearRecents()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(tab: .general)
    }

    /// The window commands should go to: the key one, else the first, else a new one.
    private func frontWindow() -> MainWindowController {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        return windows.first ?? makeWindow(restoresFrame: true)
    }

    private func makeWindow(restoresFrame: Bool) -> MainWindowController {
        let controller = MainWindowController(restoresFrame: restoresFrame)
        controller.onOpenedURL = { url in Preferences.lastOpenedPath = url.path }
        controller.onClose = { [weak self] closed in self?.windows.removeAll { $0 === closed } }
        controller.onNewWindow = { [weak self] source, asTab in self?.newWindow(from: source, asTab: asTab) }
        windows.append(controller)
        return controller
    }

    /// ⌘N / ⌘T: another window (or tab) on the same folder, so two folders can be sorted side by side.
    private func newWindow(from source: MainWindowController, asTab: Bool) {
        let controller = makeWindow(restoresFrame: false)
        guard let window = controller.window, let sourceWindow = source.window else { return }
        if asTab {
            sourceWindow.addTabbedWindow(window, ordered: .above)
        } else {
            window.setFrame(sourceWindow.frame.offsetBy(dx: 28, dy: -28), display: false)
        }
        controller.showWindow(nil)
        if let folder = source.model.folder { controller.open(folder) }
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
    static let app = Logger(subsystem: AppInfo.identifier, category: "app")
}
