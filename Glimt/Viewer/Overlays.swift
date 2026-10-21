import AppKit

/// Strictly neutral greys. A tinted surround shifts how the eye reads a photo's white balance,
/// so a viewer must not have one; the grid uses the system's own content background so it
/// meets the toolbar and status bar materials without a seam.
enum Palette {
    static let gridBackground = NSColor.controlBackgroundColor
    /// The folder columns: one step greyer than the content, so navigation and pictures read
    /// as two surfaces without a heavy rule between them.
    static let navigationBackground = adaptive(light: (0.955, 0.955, 0.955), dark: (0.155, 0.155, 0.155))
    static let viewerBackground = adaptive(light: (0.925, 0.925, 0.925), dark: (0.075, 0.075, 0.075))
    static let fullScreenBackground = NSColor.black

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}

/// Small transient label for zoom level and short confirmations ("Moved to Keepers").
final class HUDView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash(_ text: String) {
        if label.stringValue != text { label.stringValue = text }
        generation += 1
        let current = generation
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; animator().alphaValue = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.animator().alphaValue = 0 }
            }
        }
    }
}

/// Bottom-left caption with the file's name and facts, toggled with `i`.
final class InfoOverlayView: NSVisualEffectView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setLines(_ lines: [String]) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for (index, line) in lines.enumerated() {
            let label = NSTextField(labelWithString: line)
            label.font = index == 0 ? .systemFont(ofSize: 12, weight: .semibold) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = index == 0 ? .labelColor : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(label)
        }
    }
}

/// The `?` sheet: every shortcut on one panel, closed with `?` or Esc.
final class ShortcutSheetView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 28
        for group in Shortcuts.groups {
            let grid = NSGridView()
            grid.rowSpacing = 5
            grid.columnSpacing = 12
            let title = NSTextField(labelWithString: group.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            grid.addRow(with: [title, NSGridCell.emptyContentView])
            grid.cell(atColumnIndex: 0, rowIndex: 0).row?.bottomPadding = 4
            for entry in group.entries {
                let keys = NSTextField(labelWithString: entry.keys)
                keys.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                keys.textColor = .labelColor
                let action = NSTextField(labelWithString: entry.action)
                action.font = .systemFont(ofSize: 12)
                action.textColor = .secondaryLabelColor
                grid.addRow(with: [keys, action])
            }
            grid.column(at: 0).xPlacement = .trailing
            columns.addArrangedSubview(grid)
        }
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            columns.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What the window shows when there is nothing to show: welcome with recent folders, reading,
/// empty folder, no matches, unreadable file, a folder the sandbox keeps out. Left-aligned text,
/// no stock illustrations.
final class PlaceholderView: NSView {
    enum Content {
        case welcome
        case loading(folder: String)
        case noImages(folder: String)
        case noMatches
        case unreadable(file: String)
        case needsAccess(folder: URL)
    }

    /// Clicking a recent folder.
    var onOpen: ((URL) -> Void)?
    /// Clicking Allow Access, with the folder to allow.
    var onAllowAccess: ((URL) -> Void)?

    private let stack = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let recents = NSStackView()
    private let spinner = NSProgressIndicator()
    private let allowButton = NSButton(title: String(localized: "Allow Access…"), target: nil, action: nil)
    private var recentURLs: [URL] = []
    private var accessFolder: URL?
    private var isWelcome = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = Self.serif(size: 26)
        title.textColor = .labelColor
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 360
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        recents.orientation = .vertical
        recents.alignment = .leading
        recents.spacing = 2

        let heading = NSStackView(views: [title, spinner])
        heading.spacing = 10
        heading.alignment = .firstBaseline
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(allowButton)
        stack.addArrangedSubview(recents)
        stack.setCustomSpacing(22, after: detail)
        stack.setCustomSpacing(22, after: allowButton)
        allowButton.bezelStyle = .push
        allowButton.target = self
        allowButton.action = #selector(allowAccess)
        allowButton.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Set off-centre, towards the upper left, like a page rather than a dialog.
        NSLayoutConstraint.activate([
            NSLayoutConstraint(item: stack, attribute: .leading, relatedBy: .equal, toItem: self, attribute: .trailing, multiplier: 0.14, constant: 24),
            NSLayoutConstraint(item: stack, attribute: .top, relatedBy: .equal, toItem: self, attribute: .bottom, multiplier: 0.28, constant: 0),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Passes clicks through except on the recent-folder links and Allow Access.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if isWelcome, hit.isDescendant(of: recents) { return hit }
        if !allowButton.isHidden, hit.isDescendant(of: allowButton) { return hit }
        return nil
    }

    private static func serif(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    func show(_ content: Content) {
        isHidden = false
        isWelcome = false
        spinner.stopAnimation(nil)
        for view in recents.arrangedSubviews { view.removeFromSuperview() }
        allowButton.isHidden = true
        switch content {
        case .welcome:
            isWelcome = true
            title.stringValue = "Glimt"
            detail.stringValue = String(localized: "Open a folder with ⌘O, or drop one here. Number keys then sort what you see into folders.")
            // In the sandbox, offer the one permission that makes the folder columns work.
            if FolderAccess.isSandboxed, !FolderAccess.canRead(FolderAccess.home) {
                showAllow(FolderAccess.home, title: String(localized: "Allow Access to Home Folder…"))
            }
            showRecents()
        case .loading(let folder):
            title.stringValue = folder
            detail.stringValue = String(localized: "Reading the folder…")
            spinner.startAnimation(nil)
        case .noImages(let folder):
            title.stringValue = folder
            detail.stringValue = String(localized: "There are no images or videos in this folder.")
        case .noMatches:
            title.stringValue = String(localized: "Nothing matches")
            detail.stringValue = String(localized: "No file here fits the current search and filter.")
        case .unreadable(let file):
            title.stringValue = file
            detail.stringValue = String(localized: "This file can’t be opened. It may be damaged, or in a format macOS can’t read.")
        case .needsAccess(let folder):
            title.stringValue = folder.lastPathComponent
            detail.stringValue = String(localized: "Glimt needs your permission to open this folder. You only need to allow it once.")
            showAllow(folder, title: String(localized: "Allow Access…"))
        }
    }

    private func showAllow(_ folder: URL, title: String) {
        accessFolder = folder
        allowButton.title = title
        allowButton.isHidden = false
    }

    @objc private func allowAccess() {
        accessFolder.map { onAllowAccess?($0) }
    }

    private func showRecents() {
        var seen: Set<String> = []
        recentURLs = Preferences.recentURLs.compactMap { url -> URL? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let folder = isDirectory ? url : url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: folder.path), seen.insert(folder.path).inserted else { return nil }
            return folder
        }
        guard !recentURLs.isEmpty else { return }
        let header = NSTextField(labelWithString: String(localized: "Recent"))
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        recents.addArrangedSubview(header)
        recents.setCustomSpacing(6, after: header)
        for (index, url) in recentURLs.prefix(6).enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(openRecent(_:)))
            button.isBordered = false
            button.tag = index
            let parent = FolderAccess.abbreviated(url.deletingLastPathComponent().path)
            let text = NSMutableAttributedString(string: url.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.controlAccentColor,
            ])
            text.append(NSAttributedString(string: "   " + parent, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            button.attributedTitle = text
            // A truncating cell's intrinsic width is just its ellipsis; ask for the full title.
            let width = button.widthAnchor.constraint(equalToConstant: ceil(button.cell?.cellSize.width ?? 0))
            width.priority = .defaultHigh
            width.isActive = true
            button.toolTip = url.path
            recents.addArrangedSubview(button)
        }
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard recentURLs.indices.contains(sender.tag) else { return }
        onOpen?(recentURLs[sender.tag])
    }
}

/// Inset outline shown while a folder or image is dragged over the window.
final class DropHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
