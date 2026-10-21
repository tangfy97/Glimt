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

/// The nine number-key destinations along the bottom of the window. Click a slot to send
/// the current file there, drop files onto it, or right-click to change it.
final class SortBarView: NSVisualEffectView {
    weak var delegate: SortBarDelegate?
    private var slots: [SortSlotView] = []
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for slot in 0..<SortTargets.count {
            let view = SortSlotView(slot: slot)
            view.bar = self
            slots.append(view)
            stack.addArrangedSubview(view)
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .sortTargetsDidChange, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func reload() {
        for view in slots { view.folder = SortTargets.shared.folder(at: view.slot) }
    }

    func flash(_ slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot].flash()
    }
}

final class SortSlotView: NSView {
    let slot: Int
    weak var bar: SortBarView?
    var folder: URL? {
        didSet { update() }
    }

    private let number = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isDropTarget = false { didSet { needsDisplay = true } }
    private var flashLevel: CGFloat = 0 { didSet { needsDisplay = true } }

    init(slot: Int) {
        self.slot = slot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        number.stringValue = "\(slot + 1)"
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        number.textColor = .tertiaryLabelColor
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [number, name])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update() {
        if let folder {
            name.stringValue = folder.lastPathComponent
            name.textColor = .labelColor
            toolTip = String(localized: "Key \(slot + 1): move to \(folder.path) (⇧ to copy)")
        } else {
            name.stringValue = String(localized: "Set folder…")
            name.textColor = .tertiaryLabelColor
            toolTip = String(localized: "Choose a folder for key \(slot + 1)")
        }
    }

    func flash() {
        flashLevel = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.flashLevel = 0 }
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let accent = NSColor.controlAccentColor
        let fill: NSColor
        if flashLevel > 0 || isDropTarget {
            fill = accent.withAlphaComponent(0.35)
        } else if isHovered {
            fill = NSColor.labelColor.withAlphaComponent(0.08)
        } else {
            fill = NSColor.labelColor.withAlphaComponent(0.035)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = isDropTarget ? 1.5 : 0
        layer?.borderColor = accent.cgColor
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if folder == nil {
            bar.map { $0.delegate?.sortBar($0, choose: slot) }
        } else {
            bar.map { $0.delegate?.sortBar($0, send: slot, copy: event.modifierFlags.contains(.shift)) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if folder != nil {
            menu.addItem(withTitle: String(localized: "Move Here"), action: #selector(moveHere), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Copy Here"), action: #selector(copyHere), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(reveal), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: String(localized: "Choose Folder…"), action: #selector(choose), keyEquivalent: "").target = self
        if folder != nil {
            menu.addItem(withTitle: String(localized: "Remove"), action: #selector(clear), keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func moveHere() { bar.map { $0.delegate?.sortBar($0, send: slot, copy: false) } }
    @objc private func copyHere() { bar.map { $0.delegate?.sortBar($0, send: slot, copy: true) } }
    @objc private func choose() { bar.map { $0.delegate?.sortBar($0, choose: slot) } }
    @objc private func clear() { SortTargets.shared.set(nil, at: slot) }
    @objc private func reveal() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    // MARK: - Drop

    private func urls(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folder != nil, !urls(from: sender).isEmpty else { return [] }
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
