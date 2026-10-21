import AppKit

final class ThumbnailCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")

    let tile = ThumbnailTileView()
    var representedURL: URL?
    var token: ThumbnailStore.Token?

    override func loadView() {
        view = tile
    }

    override var isSelected: Bool {
        didSet { tile.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ThumbnailStore.shared.cancel(token)
        token = nil
        representedURL = nil
        tile.reset()
    }
}

/// One grid tile: image (aspect-fit, sharp corners like a print), selection plate, name with
/// tag dots, and a duration badge for videos. All layers, so scrolling never redraws.
final class ThumbnailTileView: NSView {
    private let plate = CALayer()
    private let imageLayer = CALayer()
    private let badge = CATextLayer()
    private let badgeBackground = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let nameBackground = CALayer()
    private var tagDots: [CALayer] = []

    private var imageAspect: CGFloat?
    private var tagColors: [NSColor] = []

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true; needsLayout = true } }
    }
    var showsName = true {
        didSet { nameLabel.isHidden = !showsName; needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        plate.cornerRadius = 7
        plate.cornerCurve = .continuous
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 2
        badgeBackground.cornerRadius = 4
        badgeBackground.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        badge.fontSize = 10
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badge.foregroundColor = NSColor.white.cgColor
        badge.alignmentMode = .center
        nameBackground.cornerRadius = 5
        nameBackground.cornerCurve = .continuous
        for sublayer in [plate, imageLayer, badgeBackground, badge, nameBackground] {
            sublayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        }
        layer?.addSublayer(plate)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(badgeBackground)
        layer?.addSublayer(badge)
        layer?.addSublayer(nameBackground)

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        addSubview(nameLabel)
        badge.isHidden = true
        badgeBackground.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func reset() {
        imageLayer.contents = nil
        imageAspect = nil
        badge.isHidden = true
        badgeBackground.isHidden = true
        setTags([])
    }

    func configure(name: String, tags: [NSColor], duration: Double?) {
        nameLabel.stringValue = name
        setTags(tags)
        if let duration {
            let seconds = Int(duration.rounded())
            badge.string = seconds >= 3600
                ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
            badge.isHidden = false
            badgeBackground.isHidden = false
        }
        needsLayout = true
    }

    func setImage(_ contents: Any?, aspect: CGFloat) {
        imageLayer.contents = contents
        imageAspect = aspect
        needsLayout = true
    }

    func setDuration(_ duration: Double?) {
        configure(name: nameLabel.stringValue, tags: tagColors, duration: duration)
    }

    private func setTags(_ colors: [NSColor]) {
        tagColors = colors
        for dot in tagDots { dot.removeFromSuperlayer() }
        tagDots = colors.prefix(3).map { _ in
            let dot = CALayer()
            dot.cornerRadius = 4
            dot.borderWidth = 1
            layer?.addSublayer(dot)
            return dot
        }
        needsDisplay = true
    }

    /// Where the picture itself sits, for the zoom transition.
    var imageRect: NSRect {
        let square = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.width).insetBy(dx: 6, dy: 6)
        guard let aspect = imageAspect, aspect > 0 else { return square }
        if aspect >= 1 {
            let height = square.width / aspect
            return NSRect(x: square.minX, y: square.midY - height / 2, width: square.width, height: height)
        }
        let width = square.height * aspect
        return NSRect(x: square.midX - width / 2, y: square.minY, width: width, height: square.height)
    }

    var imageContents: Any? { imageLayer.contents }

    override func layout() {
        super.layout()
        let image = imageRect
        imageLayer.frame = image
        plate.frame = image.insetBy(dx: -5, dy: -5)

        let badgeSize = badge.preferredFrameSize()
        let badgeFrame = NSRect(x: image.maxX - badgeSize.width - 10, y: image.maxY - badgeSize.height - 7,
                                width: badgeSize.width + 6, height: badgeSize.height + 2)
        badgeBackground.frame = badgeFrame
        badge.frame = badgeFrame.offsetBy(dx: 0, dy: 1)
        badge.contentsScale = window?.backingScaleFactor ?? 2

        guard showsName else {
            nameBackground.isHidden = true
            return
        }
        let dotsWidth = CGFloat(tagDots.count) * 10
        let maxText = bounds.width - 12 - dotsWidth
        let textWidth = min(nameLabel.intrinsicContentSize.width, maxText)
        let total = textWidth + dotsWidth
        let y = bounds.width + 2
        var x = (bounds.width - total) / 2
        for dot in tagDots {
            dot.frame = NSRect(x: x, y: y + 5, width: 8, height: 8)
            x += 10
        }
        nameLabel.frame = NSRect(x: x, y: y, width: textWidth, height: 17)
        nameBackground.frame = nameLabel.frame.insetBy(dx: -5, dy: -1)
        nameBackground.isHidden = !isSelected
    }

    override func updateLayer() {
        let accent = NSColor.controlAccentColor
        plate.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
        plate.borderWidth = isSelected ? 2 : 0
        plate.borderColor = accent.cgColor
        nameBackground.backgroundColor = accent.cgColor
        nameLabel.textColor = isSelected ? .white : .secondaryLabelColor
        for (dot, color) in zip(tagDots, tagColors) {
            dot.backgroundColor = color.cgColor
            dot.borderColor = Palette.gridBackground.cgColor
        }
    }
}
