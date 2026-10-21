import AppKit
import Observation
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    enum Tab: Hashable {
        case general, sorting, shortcuts
    }

    @Observable
    final class Navigation {
        var tab = Tab.general
    }

    static let shared = SettingsWindowController()
    private let navigation = Navigation()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView(navigation: navigation))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(tab: Tab) {
        navigation.tab = tab
        showWindow(nil)
    }
}

struct SettingsView: View {
    @Bindable var navigation: SettingsWindowController.Navigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsWindowController.Tab.general)
            SortingSettings().tabItem { Label("Sorting", systemImage: "tray.2") }.tag(SettingsWindowController.Tab.sorting)
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsWindowController.Tab.shortcuts)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.appearance) private var appearance = "system"
    @AppStorage(Preferences.Key.showFileNames) private var showFileNames = true
    @AppStorage(Preferences.Key.upscaleSmallImages) private var upscaleSmallImages = false
    @AppStorage(Preferences.Key.showsLargeImagesAtActualSize) private var actualSize = false
    @AppStorage(Preferences.Key.keepsZoomWhenPaging) private var keepZoom = false
    @AppStorage(Preferences.Key.slideshowInterval) private var slideshowInterval = 4.0
    @AppStorage(Preferences.Key.slideshowLoops) private var slideshowLoops = true
    @AppStorage(Preferences.Key.slideshowShuffles) private var slideshowShuffles = false
    @State private var cacheSize: Int64?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Match the system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Show file names under thumbnails", isOn: $showFileNames)
            }
            Section("Viewer") {
                Toggle("Enlarge small images to fill the window", isOn: $upscaleSmallImages)
                Toggle("Open large images at actual size", isOn: $actualSize)
                Toggle("Keep the zoom when moving to the next image", isOn: $keepZoom)
            }
            Section("Slideshow") {
                LabeledContent("Each image for") {
                    HStack {
                        Slider(value: $slideshowInterval, in: 1...20, step: 1)
                            .frame(width: 180)
                        Text("\(Int(slideshowInterval)) s")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Start over after the last image", isOn: $slideshowLoops)
                Toggle("Shuffle", isOn: $slideshowShuffles)
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
        .onChange(of: appearance) { Preferences.applyAppearance() }
    }
}

private struct SortingSettings: View {
    @AppStorage(Preferences.Key.numberKeysCopy) private var numberKeysCopy = false
    @AppStorage(Preferences.Key.movesCompanions) private var movesCompanions = true
    private let targets = SortTargets.shared

    var body: some View {
        Form {
            Section {
                Picker("Number keys", selection: $numberKeysCopy) {
                    Text("Move the file (⇧ copies)").tag(false)
                    Text("Copy the file (⇧ moves)").tag(true)
                }
                Toggle(isOn: $movesCompanions) {
                    Text("Keep RAW+JPEG pairs together")
                    Text("Files with the same name, Live Photo movies and .xmp sidecars move, copy, rename and go to the Trash together.")
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
    var body: some View {
        Form {
            ForEach(Shortcuts.groups) { group in
                Section(group.title) {
                    ForEach(group.entries, id: \.keys) { entry in
                        LabeledContent(entry.action) {
                            Text(entry.keys).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}
