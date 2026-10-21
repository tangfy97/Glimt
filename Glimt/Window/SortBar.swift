import AppKit

@MainActor
protocol SortBarDelegate: AnyObject {
    func sortBar(_ bar: SortBarView, send slot: Int, copy: Bool)
    func sortBar(_ bar: SortBarView, drop urls: [URL], on slot: Int, copy: Bool)
    func sortBar(_ bar: SortBarView, choose slot: Int)
}

extension Notification.Name {
    static let sortTargetsDidChange = Notification.Name("GlimtSortTargetsDidChange")
}

/// A legend along the bottom of the window: each number key and the folder it sends files to.
/// Only folders that are set appear, followed by one link to add another. Click a name to send
/// the current file there, drop files onto it, or right-click to change it.
final class SortBarView: NSVisualEffectView {
    static let height: CGFloat = 30

    weak var delegate: SortBarDelegate?
    private let stack = NSStackView()
    private var entries: [SortSlotView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .sortTargetsDidChange, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        entries = []
        let folders = SortTargets.shared.folders
        for (slot, folder) in folders.enumerated() {
            guard let folder else { continue }
            let entry = SortSlotView(slot: slot, folder: folder)
            entry.bar = self
            entries.append(entry)
            stack.addArrangedSubview(entry)
        }
        if let free = folders.firstIndex(where: { $0 == nil }) {
            if entries.isEmpty {
                let hint = NSTextField(labelWithString: String(localized: "Number keys move files into sort folders."))
                hint.font = .systemFont(ofSize: 12)
                hint.textColor = .secondaryLabelColor
                stack.addArrangedSubview(hint)
                stack.setCustomSpacing(8, after: hint)
            }
            let add = NSButton(title: "", target: self, action: #selector(addFolder(_:)))
            add.isBordered = false
            add.tag = free
            add.attributedTitle = NSAttributedString(string: String(localized: "Add sort folder…"), attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor,
            ])
            stack.addArrangedSubview(add)
        }
    }

    @objc private func addFolder(_ sender: NSButton) {
        delegate?.sortBar(self, choose: sender.tag)
    }

    func flash(_ slot: Int) {
        entries.first { $0.slot == slot }?.flash()
    }
}

final class SortSlotView: NSView {
    let slot: Int
    let folder: URL
    weak var bar: SortBarView?

    private let key = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let underline = CALayer()
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isDropTarget = false { didSet { needsDisplay = true } }
    private var isFlashing = false { didSet { needsDisplay = true } }

    init(slot: Int, folder: URL) {
        self.slot = slot
        self.folder = folder
        super.init(frame: .zero)
        wantsLayer = true
        key.stringValue = "\(slot + 1)"
        key.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        name.stringValue = folder.lastPathComponent
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [key, name])
        stack.spacing = 5
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: SortBarView.height),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
        underline.actions = ["frame": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(underline)
        toolTip = String(localized: "Key \(slot + 1) moves files to \((folder.path as NSString).abbreviatingWithTildeInPath). Hold ⇧ to copy.")
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func flash() {
        isFlashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.isFlashing = false }
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let active = isFlashing || isDropTarget
        key.textColor = active ? .controlAccentColor : .tertiaryLabelColor
        name.textColor = active ? .controlAccentColor : (isHovered ? .labelColor : .secondaryLabelColor)
        underline.backgroundColor = NSColor.controlAccentColor.cgColor
        underline.isHidden = !(isDropTarget || isHovered)
        underline.opacity = isDropTarget ? 1 : 0.5
        underline.frame = NSRect(x: 0, y: 5, width: bounds.width, height: isDropTarget ? 2 : 1)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), let bar else { return }
        bar.delegate?.sortBar(bar, send: slot, copy: event.modifierFlags.contains(.shift))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Move Here"), action: #selector(moveHere), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Copy Here"), action: #selector(copyHere), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Choose Another Folder…"), action: #selector(choose), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Remove from Sort Bar"), action: #selector(clear), keyEquivalent: "").target = self
        return menu
    }

    @objc private func moveHere() { bar.map { $0.delegate?.sortBar($0, send: slot, copy: false) } }
    @objc private func copyHere() { bar.map { $0.delegate?.sortBar($0, send: slot, copy: true) } }
    @objc private func choose() { bar.map { $0.delegate?.sortBar($0, choose: slot) } }
    @objc private func clear() { SortTargets.shared.set(nil, at: slot) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([folder]) }

    // MARK: - Drop

    private func urls(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        isDropTarget = true
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isDropTarget else { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let files = urls(from: sender)
        guard !files.isEmpty, let bar else { return false }
        bar.delegate?.sortBar(bar, drop: files, on: slot, copy: NSEvent.modifierFlags.contains(.option))
        return true
    }
}
