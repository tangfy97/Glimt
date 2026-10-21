import AppKit
import AVKit

enum Navigation {
    case next, previous, first, last
}

@MainActor
protocol ViewerViewDelegate: AnyObject {
    func viewer(_ viewer: ViewerView, navigate: Navigation)
    /// The user is zooming in; a sharper decode will probably be needed.
    func viewerWantsDetail(_ viewer: ViewerView)
    /// A pinch, smart zoom or zoom command has come to rest.
    func viewerDidSettleZoom(_ viewer: ViewerView)
    func viewer(_ viewer: ViewerView, open url: URL)
    func viewerPressedSpace(_ viewer: ViewerView, shift: Bool)
    /// Return false to let Escape fall through (e.g. to leave full screen).
    func viewerPressedEscape(_ viewer: ViewerView) -> Bool
}

/// Zoomable image (or video), overlays, keyboard and drop handling. It knows nothing about
/// folders or decoding; the viewer controller feeds it bitmaps.
final class ViewerView: NSView {
    weak var delegate: ViewerViewDelegate?

    private let scrollView = ZoomScrollView()
    private let canvas = ImageCanvasView()
    private let placeholder = PlaceholderView()
    private let hud = HUDView()
    private let dropHighlight = DropHighlightView()

    private var sourceSize: CGSize = .zero
    private var contentsLongestSide = 0
    private var zoomAnimation: MagnificationAnimation?
    private var playerView: AVPlayerView?

    var usesFullScreenBackground = false {
        didSet { needsDisplay = true }
    }

    private(set) var isFitMode = true
    private(set) var isLiveMagnifying = false

    var hasImage: Bool { sourceSize != .zero }

    /// True while the layer holds fewer pixels than a full decode would give.
    var isShowingReducedResolution: Bool {
        hasImage && contentsLongestSide < ImageDecoder.fullLongestSide(for: sourceSize)
    }

    private var clipView: NSClipView { scrollView.contentView }
    private var visibleCenter: NSPoint { NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.viewer = self
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.allowsMagnification = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.usesPredominantAxisScrolling = false
        addSubview(scrollView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        dropHighlight.frame = bounds.insetBy(dx: 6, dy: 6)
        dropHighlight.autoresizingMask = [.width, .height]
        addSubview(dropHighlight)

        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor),
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(liveMagnifyWillStart(_:)), name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveMagnifyDidEnd(_:)), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        registerForDraggedTypes([.fileURL])
        placeholder.show(.welcome)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (usesFullScreenBackground ? Palette.fullScreenBackground : Palette.viewerBackground).cgColor
    }

    func focus() {
        window?.makeFirstResponder(scrollView)
    }

    /// Hides the picture (not the backdrop) while a transition layer stands in for it.
    func setContentHidden(_ hidden: Bool) {
        scrollView.isHidden = hidden
        playerView?.alphaValue = hidden ? 0 : 1
    }

    /// The image area: below the toolbar in a window, the whole screen in full screen.
    private var contentArea: NSRect {
        guard let window else { return bounds }
        let area = convert(window.contentLayoutRect, from: nil).intersection(bounds)
        return area.isEmpty ? bounds : area
    }

    override func layout() {
        super.layout()
        let area = contentArea
        if scrollView.frame != area { scrollView.frame = area }
        playerView?.frame = area
        updateMagnificationLimits(refit: isFitMode)
    }

    // MARK: - Content

    /// Layer-backed view layers have implicit animations off, so no explicit transaction is
    /// needed; an explicit outermost one would also force a synchronous commit right here.
    func display(_ image: DecodedImage, resetZoom: Bool) {
        placeholder.isHidden = true
        hideVideo()
        let sourceSize = image.sourceSize
        if resetZoom || sourceSize != self.sourceSize {
            zoomAnimation?.stop()
            zoomAnimation = nil
            self.sourceSize = sourceSize
            canvas.frame = CGRect(origin: .zero, size: sourceSize)
            isFitMode = true
            updateMagnificationLimits(refit: true)
            clipView.setBoundsOrigin(clipView.constrainBoundsRect(clipView.bounds).origin)
        }
        canvas.setContents(image.surface)
        contentsLongestSide = image.longestSide
        updateFilter()
    }

    /// One frame of an animated image, same geometry as the decoded first frame.
    func displayAnimationFrame(_ frame: CGImage) {
        guard hasImage else { return }
        canvas.setContents(frame)
        contentsLongestSide = max(frame.width, frame.height)
    }

    // MARK: - Video

    func showVideo(_ url: URL) {
        clearImage()
        placeholder.isHidden = true
        let playerView = self.playerView ?? {
            let view = AVPlayerView()
            view.controlsStyle = .floating
            view.showsFullScreenToggleButton = false
            view.videoGravity = .resizeAspect
            addSubview(view, positioned: .above, relativeTo: scrollView)
            self.playerView = view
            return view
        }()
        playerView.frame = contentArea
        playerView.isHidden = false
        let player = AVPlayer(url: url)
        playerView.player = player
        player.play()
        focus()
    }

    func hideVideo() {
        guard let playerView, !playerView.isHidden else { return }
        playerView.player?.pause()
        playerView.player = nil
        playerView.isHidden = true
    }

    var isShowingVideo: Bool { playerView?.isHidden == false }

    func toggleVideoPlayback() {
        guard let player = playerView?.player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    // MARK: - Transition geometry

    /// Where an image of `size` sits when fitted, in this view's coordinates.
    func fitRect(for size: CGSize) -> NSRect {
        let area = contentArea
        guard size.width > 0, size.height > 0 else { return area }
        var scale = min(area.width / size.width, area.height / size.height)
        if !Preferences.upscaleSmallImages { scale = min(scale, 1) }
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// The displayed picture's rect and contents, when it is shown whole (not zoomed in).
    var fittedImage: (rect: NSRect, contents: Any)? {
        guard hasImage, isFitMode, !isShowingVideo, let contents = canvas.layer?.contents else { return nil }
        return (fitRect(for: sourceSize), contents)
    }

    func showPlaceholder(_ content: PlaceholderView.Content) {
        zoomAnimation?.stop()
        zoomAnimation = nil
        canvas.setContents(nil)
        sourceSize = .zero
        contentsLongestSide = 0
        placeholder.show(content)
    }

    /// Blank frame while paging faster than decodes arrive: better than a stale image
    /// under the new file's name.
    func clearImage() {
        guard hasImage else { return }
        zoomAnimation?.stop()
        zoomAnimation = nil
        canvas.setContents(nil)
        sourceSize = .zero
        contentsLongestSide = 0
    }

    func flashMessage(_ text: String) {
        hud.flash(text)
    }

    // MARK: - Zoom

    var fitMagnification: CGFloat {
        let available = scrollView.contentSize
        guard hasImage, available.width > 0, available.height > 0 else { return 1 }
        let fit = min(available.width / sourceSize.width, available.height / sourceSize.height)
        // Small images stay at 100% unless the user asked to enlarge them.
        return Preferences.upscaleSmallImages ? fit : min(fit, 1)
    }

    func zoomToFit(animated: Bool = true) {
        setMagnification(fitMagnification, around: visibleCenter, animated: animated)
    }

    func zoomToActualSize() {
        delegate?.viewerWantsDetail(self)
        setMagnification(1, around: visibleCenter, animated: true)
    }

    func zoom(by factor: CGFloat, around windowPoint: NSPoint? = nil, animated: Bool = true) {
        guard hasImage else { return }
        if factor > 1 { delegate?.viewerWantsDetail(self) }
        let point = windowPoint.map { clipView.convert($0, from: nil) } ?? visibleCenter
        let base = zoomAnimation == nil ? scrollView.magnification : targetMagnification
        setMagnification(base * factor, around: point, animated: animated)
    }

    func smartMagnify(at windowPoint: NSPoint) {
        guard hasImage else { return }
        if isFitMode {
            let fit = fitMagnification
            let target = fit < 1 ? min(1, fit * 4) : fit * 2
            delegate?.viewerWantsDetail(self)
            setMagnification(target, around: clipView.convert(windowPoint, from: nil), animated: true)
        } else {
            zoomToFit()
        }
    }

    func liveMagnificationChanged() {
        updateFilter()
        hud.flash(percentText(scrollView.magnification))
    }

    private var targetMagnification: CGFloat = 1

    private func setMagnification(_ magnification: CGFloat, around point: NSPoint, animated: Bool) {
        guard hasImage else { return }
        zoomAnimation?.stop()
        zoomAnimation = nil
        let target = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        targetMagnification = target
        hud.flash(percentText(target))
        if animated, abs(target - scrollView.magnification) > 0.0001 {
            zoomAnimation = MagnificationAnimation(scrollView: scrollView, to: target, around: point) { [weak self] in
                self?.magnificationSettled()
            }
            updateFilter(for: max(target, scrollView.magnification))
        } else {
            scrollView.setMagnification(target, centeredAt: point)
            magnificationSettled()
        }
    }

    private func magnificationSettled() {
        zoomAnimation = nil
        let fit = fitMagnification
        isFitMode = abs(scrollView.magnification - fit) <= fit * 0.001
        updateFilter()
        delegate?.viewerDidSettleZoom(self)
    }

    private func updateMagnificationLimits(refit: Bool) {
        guard hasImage else { return }
        let fit = fitMagnification
        scrollView.minMagnification = fit
        scrollView.maxMagnification = max(fit, 16)
        if refit || scrollView.magnification < fit {
            scrollView.magnification = fit
            isFitMode = true
        }
    }

    private func updateFilter(for magnification: CGFloat? = nil) {
        guard contentsLongestSide > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let sourceLongest = max(sourceSize.width, sourceSize.height)
        let screenPixelsPerContentPixel = (magnification ?? scrollView.magnification) * scale * sourceLongest / CGFloat(contentsLongestSide)
        canvas.setPixelated(screenPixelsPerContentPixel >= 4)
    }

    private func percentText(_ magnification: CGFloat) -> String {
        "\(Int((magnification * 100).rounded()))%"
    }

    @objc private func liveMagnifyWillStart(_ notification: Notification) {
        zoomAnimation?.stop()
        zoomAnimation = nil
        isLiveMagnifying = true
        // Start the full decode as the fingers land, not when they lift.
        delegate?.viewerWantsDetail(self)
    }

    @objc private func liveMagnifyDidEnd(_ notification: Notification) {
        isLiveMagnifying = false
        magnificationSettled()
    }

    // MARK: - Keyboard

    func navigate(_ navigation: Navigation) {
        delegate?.viewer(self, navigate: navigation)
    }

    // Window views see key events before the main menu does, so bare keys like the arrows
    // are handled here and never flash the menu bar on every page turn.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only while the viewer is on screen; otherwise the grid owns the arrow keys.
        guard !isHiddenOrHasHiddenAncestor else { return false }
        return handleKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch Int(scalar.value) {
        case NSRightArrowFunctionKey, NSPageDownFunctionKey:
            navigate(.next)
        case NSLeftArrowFunctionKey, NSPageUpFunctionKey:
            navigate(.previous)
        case NSDownArrowFunctionKey:
            if isFitMode { navigate(.next) } else { pan(byFractionOfHeight: -0.2) }
        case NSUpArrowFunctionKey:
            if isFitMode { navigate(.previous) } else { pan(byFractionOfHeight: 0.2) }
        case NSHomeFunctionKey:
            navigate(.first)
        case NSEndFunctionKey:
            navigate(.last)
        case 0x20:
            delegate?.viewerPressedSpace(self, shift: shift)
        case 0x1B:
            if delegate?.viewerPressedEscape(self) != true {
                guard window?.styleMask.contains(.fullScreen) == true else { return false }
                window?.toggleFullScreen(nil)
            }
        case 0x66 where !shift: // f
            window?.toggleFullScreen(nil)
        default:
            return false
        }
        return true
    }

    private func pan(byFractionOfHeight fraction: CGFloat) {
        var bounds = clipView.bounds
        bounds.origin.y += bounds.height * fraction
        let origin = clipView.constrainBoundsRect(bounds).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            clipView.animator().setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileURL(from: sender) != nil else { return [] }
        dropHighlight.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHighlight.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight.isHidden = true
        guard let url = fileURL(from: sender) else { return false }
        delegate?.viewer(self, open: url)
        return true
    }

    private func fileURL(from info: NSDraggingInfo) -> URL? {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return objects?.first as? URL
    }
}
