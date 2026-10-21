import AppKit

/// Design review aid: `GLIMT_SNAPSHOT=/path/prefix` renders the window's content into PNGs
/// (grid, then viewer) and quits. Renders the app's own views, so it needs no screen-recording
/// permission. The toolbar lives outside the content view and is not included.
@MainActor
final class Snapshot {
    private let window: MainWindowController
    private let prefix: String

    init?(window: MainWindowController) {
        guard let prefix = ProcessInfo.processInfo.environment["GLIMT_SNAPSHOT"] else { return nil }
        self.window = window
        self.prefix = prefix
    }

    func start() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            capture("grid")
            if !window.model.media.isEmpty {
                window.openViewer(at: 0, animated: false)
                try? await Task.sleep(for: .seconds(1.5))
                capture("viewer")
            }
            if ProcessInfo.processInfo.environment["GLIMT_SNAPSHOT_SETTINGS"] != nil {
                for (index, tab) in SettingsWindowController.Tab.allCases.enumerated() {
                    SettingsWindowController.shared.show(tab: tab)
                    try? await Task.sleep(for: .seconds(1))
                    capture("settings-\(index)", of: SettingsWindowController.shared.window)
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// SwiftUI panes don't render through `cacheDisplay` in dark mode; check those in light mode.
    private func capture(_ name: String, of target: NSWindow? = nil) {
        guard let view = (target ?? window.window)?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: "\(prefix)-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }
}
