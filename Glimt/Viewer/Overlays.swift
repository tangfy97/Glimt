import AppKit

/// Warm paper in light mode, soft charcoal in dark mode.
enum Palette {
    static let gridBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.105, green: 0.105, blue: 0.11, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.957, blue: 0.94, alpha: 1)
    }
    static let viewerBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.075, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.918, blue: 0.9, alpha: 1)
    }
    static let fullScreenBackground = NSColor.black
}

/// Small transient capsule for zoom level and edge-of-folder hints.
final class HUDView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash(_ text: String) {
        if label.stringValue != text { label.stringValue = text }
        generation += 1
        let current = generation
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0.35; self.animator().alphaValue = 0 }
            }
        }
    }
}

/// Centered message for the welcome, empty-folder and unreadable-file states.
final class PlaceholderView: NSView {
    enum Content {
        case welcome
        case loading
        case noImages(folder: String)
        case noMatches
        case unreadable(file: String)
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.symbolConfiguration = .init(pointSize: 44, weight: .ultraLight)
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 17, weight: .medium)
        title.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .tertiaryLabelColor
        for label in [title, detail] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
        }

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ content: Content) {
        isHidden = false
        let symbol: String
        switch content {
        case .welcome:
            symbol = "photo.on.rectangle.angled"
            title.stringValue = String(localized: "Open a folder of images")
            detail.stringValue = String(localized: "Press ⌘O, or drop a folder or image here.")
        case .loading:
            symbol = "photo.stack"
            title.stringValue = String(localized: "Reading folder…")
            detail.stringValue = ""
        case .noImages(let folder):
            symbol = "questionmark.folder"
            title.stringValue = String(localized: "No images in “\(folder)”")
            detail.stringValue = String(localized: "Drop another folder here, or press ⌘O.")
        case .noMatches:
            symbol = "magnifyingglass"
            title.stringValue = String(localized: "Nothing matches")
            detail.stringValue = String(localized: "Try another search or filter.")
        case .unreadable(let file):
            symbol = "exclamationmark.triangle"
            title.stringValue = String(localized: "Can’t open “\(file)”")
            detail.stringValue = String(localized: "The file may be damaged or in an unsupported format.")
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        detail.isHidden = detail.stringValue.isEmpty
    }
}

/// Inset outline shown while a folder or image is dragged over the window.
final class DropHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
