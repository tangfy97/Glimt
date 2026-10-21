import AppKit
import SwiftUI

/// The Settings window in the standard Mac layout: toolbar tabs, right-aligned labels ending in
/// a colon, checkboxes. Two panes; keyboard shortcuts live under Help instead.
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Tab: Int, CaseIterable {
        case general, sorting
    }

    static let shared = SettingsWindowController()
    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        // No cross-fade: with it, the window resizes while both panes are half drawn, which
        // reads as a flash. Panes are sized up front, so the switch is a single clean resize.
        tabs.transitionOptions = [.allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true
        tabs.addTabViewItem(Self.item(GeneralPane(), title: String(localized: "General"), symbol: "gearshape"))
        tabs.addTabViewItem(Self.item(SortingPane(), title: String(localized: "Sorting"), symbol: "tray.2"))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        // The window takes the selected pane's name, as macOS Settings windows do.
        window.title = tabs.tabViewItems.first?.label ?? String(localized: "Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func item(_ pane: some View, title: String, symbol: String) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: pane)
        hosting.title = title
        hosting.sizingOptions = [.preferredContentSize]
        // Know the size before the first switch, so the window never resizes around an empty pane.
        hosting.preferredContentSize = hosting.view.fittingSize
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func show(tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        showWindow(nil)
    }
}

/// Shared frame for both panes, so labels line up at the same x when switching tabs.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.columns)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(width: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @AppStorage(Preferences.Key.appearance) private var appearance = "system"
    @AppStorage(Preferences.Key.showFileNames) private var showFileNames = true
    @AppStorage(Preferences.Key.upscaleSmallImages) private var upscaleSmallImages = false
    @AppStorage(Preferences.Key.showsLargeImagesAtActualSize) private var actualSize = false
    @AppStorage(Preferences.Key.keepsZoomWhenPaging) private var keepZoom = false
    @AppStorage(Preferences.Key.slideshowInterval) private var interval = 4.0
    @AppStorage(Preferences.Key.slideshowLoops) private var loops = true
    @AppStorage(Preferences.Key.slideshowShuffles) private var shuffles = false
    @State private var cacheSize: Int64?

    /// The same steps `[` and `]` move through during a slideshow.
    private let intervals: [Double] = [0.5, 1, 1.5, 2, 3, 4, 5, 7, 10, 15, 20, 30]

    var body: some View {
        Pane {
            Picker("Appearance:", selection: $appearance) {
                Text("Automatic").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .fixedSize()

            Toggle("Show names", isOn: $showFileNames)
                .labeledContent("Grid:")
                .padding(.top, 8)

            LabeledContent("Viewer:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enlarge small images", isOn: $upscaleSmallImages)
                    Toggle("Open large images at 100%", isOn: $actualSize)
                    Toggle("Keep zoom between images", isOn: $keepZoom)
                }
            }
            .padding(.top, 8)

            LabeledContent("Slideshow:") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $interval) {
                        ForEach(intervals, id: \.self) { seconds in
                            Text(Self.format(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Toggle("Loop", isOn: $loops)
                    Toggle("Shuffle", isOn: $shuffles)
                }
            }
            .padding(.top, 8)

            LabeledContent("Thumbnail cache:") {
                HStack(spacing: 12) {
                    Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        ThumbnailStore.shared.clearDiskCache()
                        Task { cacheSize = await ThumbnailStore.diskUsage() }
                    }
                    .disabled(cacheSize == 0)
                }
            }
            .padding(.top, 8)
        }
        .toggleStyle(.checkbox)
        .task { cacheSize = await ThumbnailStore.diskUsage() }
        .onChange(of: appearance) { Preferences.applyAppearance() }
    }

    private static func format(_ seconds: Double) -> String {
        let value = seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return String(localized: "\(value) s")
    }
}

private struct SortingPane: View {
    @AppStorage(Preferences.Key.numberKeysCopy) private var numberKeysCopy = false
    @AppStorage(Preferences.Key.movesCompanions) private var movesCompanions = true
    private let targets = SortTargets.shared

    var body: some View {
        Pane {
            LabeledContent("Number keys:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $numberKeysCopy) {
                        Text("Move").tag(false)
                        Text("Copy").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text("Hold ⇧ to do the other.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Keep RAW and JPEG together", isOn: $movesCompanions)
                .toggleStyle(.checkbox)
                .help("Files with the same name, Live Photo movies and .xmp sidecars travel with the photo.")
                .labeledContent("Pairs:")
                .padding(.top, 8)

            LabeledContent("Folders:") {
                FolderList(targets: targets)
            }
            .padding(.top, 8)
        }
    }
}

/// Only the keys that have a folder, then one way to add another. No rows of "Not set".
private struct FolderList: View {
    let targets: SortTargets

    private var assigned: [(slot: Int, folder: URL)] {
        targets.folders.enumerated().compactMap { slot, folder in folder.map { (slot, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assigned.isEmpty {
                Text("None yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(assigned, id: \.slot) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(entry.slot + 1)")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.folder.lastPathComponent)
                        Text(FolderAccess.abbreviated(entry.folder.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(width: 180, alignment: .leading)
                    Button("Change…") { choose(entry.slot) }
                        .controlSize(.small)
                    Button {
                        targets.set(nil, at: entry.slot)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                }
            }
            if let free = targets.folders.firstIndex(where: { $0 == nil }) {
                Button("Add Folder…") { choose(free) }
            }
        }
    }

    private func choose(_ slot: Int) {
        Task { _ = await targets.choose(for: slot, attachedTo: SettingsWindowController.shared.window) }
    }
}

private extension View {
    /// A control whose own label is its text, placed in the form's label column under `label`.
    func labeledContent(_ label: LocalizedStringKey) -> some View {
        LabeledContent(label) { self }
    }
}

/// Help ▸ Keyboard Shortcuts outside the viewer: the same sheet the viewer shows for `?`.
@MainActor
final class ShortcutsPanel {
    static let shared = ShortcutsPanel()
    private lazy var panel: NSPanel = {
        let sheet = ShortcutSheetView()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: sheet.fittingSize),
                            styleMask: [.titled, .closable, .hudWindow, .utilityWindow], backing: .buffered, defer: true)
        panel.title = String(localized: "Keyboard Shortcuts")
        panel.contentView = sheet
        panel.isReleasedWhenClosed = false
        panel.center()
        return panel
    }()

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }
}
