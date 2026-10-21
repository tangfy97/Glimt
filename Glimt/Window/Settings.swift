import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SortingSettings().tabItem { Label("Sorting", systemImage: "tray.2") }
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.showFileNames) private var showFileNames = true
    @AppStorage(Preferences.Key.upscaleSmallImages) private var upscaleSmallImages = false
    @AppStorage(Preferences.Key.slideshowInterval) private var slideshowInterval = 4.0
    @AppStorage(Preferences.Key.slideshowLoops) private var slideshowLoops = true
    @AppStorage(Preferences.Key.showSortBar) private var showSortBar = true
    @State private var cacheSize: Int64?

    var body: some View {
        Form {
            Section("Browsing") {
                Toggle("Show file names under thumbnails", isOn: $showFileNames)
                Toggle("Show the sort bar", isOn: $showSortBar)
            }
            Section("Viewing") {
                Toggle("Enlarge small images to fill the window", isOn: $upscaleSmallImages)
            }
            Section("Slideshow") {
                LabeledContent("Show each image for") {
                    HStack {
                        Slider(value: $slideshowInterval, in: 1...20, step: 1)
                            .frame(width: 180)
                        Text("\(Int(slideshowInterval)) s")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Start over after the last image", isOn: $slideshowLoops)
            }
            Section("Thumbnail cache") {
                LabeledContent("Size on disk") {
                    HStack {
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .monospacedDigit()
                        Button("Clear") {
                            ThumbnailStore.shared.clearDiskCache()
                            Task { cacheSize = await ThumbnailStore.diskUsage() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { cacheSize = await ThumbnailStore.diskUsage() }
    }
}

private struct SortingSettings: View {
    @AppStorage(Preferences.Key.numberKeysCopy) private var numberKeysCopy = false
    private let targets = SortTargets.shared

    var body: some View {
        Form {
            Section {
                Picker("Number keys", selection: $numberKeysCopy) {
                    Text("Move the file (⇧ copies)").tag(false)
                    Text("Copy the file (⇧ moves)").tag(true)
                }
            }
            Section("Folders") {
                ForEach(0..<SortTargets.count, id: \.self) { slot in
                    HStack(spacing: 10) {
                        Text("\(slot + 1)")
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        if let folder = targets.folders[slot] {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folder.lastPathComponent)
                                Text((folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            Text("Not set").foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Choose…") {
                            Task { _ = await targets.choose(for: slot, attachedTo: NSApp.keyWindow) }
                        }
                        if targets.folders[slot] != nil {
                            Button {
                                targets.set(nil, at: slot)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsSettings: View {
    private let groups: [(String, [(String, String)])] = [
        ("Browse", [
            ("← →  Space  ⇧Space", "Previous / next image"),
            ("Home  End", "First / last image"),
            ("Return  Double-click", "Open image"),
            ("Esc", "Back to the grid"),
            ("⌘↑", "Enclosing folder"),
            ("⌘F", "Search file names"),
        ]),
        ("Sort", [
            ("1 – 9", "Move to sort folder"),
            ("⇧1 – ⇧9", "Copy to sort folder"),
            ("⌥1 – ⌥9", "Choose the folder for a key"),
            ("⌘⌫", "Move to Trash"),
            ("⌃1 – ⌃7  ⌃0", "Toggle Finder tag / clear tags"),
            ("⌘Z  ⇧⌘Z", "Undo / redo"),
        ]),
        ("View", [
            ("Pinch  ⌘=  ⌘−", "Zoom (thumbnails in the grid)"),
            ("Double-tap  ⌘0  ⌘9", "Smart zoom / actual size / fit"),
            ("⌘L  ⌘R", "Rotate left / right (lossless)"),
            ("F  ⌃⌘F", "Full screen"),
            ("⌥⌘P", "Slideshow (Space pauses)"),
            ("⌘I", "Info"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.0) { shortcut in
                        LabeledContent(shortcut.1) {
                            Text(shortcut.0).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}
