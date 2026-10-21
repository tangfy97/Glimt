import AppKit
import QuartzCore

/// AppKit's own magnifying scroll view, so pinch, smart zoom, inertia and rubber-banding
/// are the same system-composited behaviour as Preview and Safari.
final class ZoomScrollView: NSScrollView {
    weak var viewer: ViewerView?

    private var swipeDistance: CGFloat = 0
    private var swipeConsumed = false

    override var acceptsFirstResponder: Bool { true }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        viewer?.liveMagnificationChanged()
    }

    override func smartMagnify(with event: NSEvent) {
        viewer?.smartMagnify(at: event.locationInWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewer, viewer.hasImage else {
            super.scrollWheel(with: event)
            return
        }
        if !event.modifierFlags.intersection([.option, .command]).isEmpty {
            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            viewer.zoom(by: exp(event.scrollingDeltaY * step), around: event.locationInWindow, animated: false)
            return
        }
        guard viewer.isFitMode else {
            super.scrollWheel(with: event)
            return
        }
        // At fit there is nothing to pan, so scrolling turns pages instead.
        if event.hasPreciseScrollingDeltas {
            trackpadSwipe(event)
        } else if event.scrollingDeltaY != 0 {
            viewer.navigate(event.scrollingDeltaY < 0 ? .next : .previous)
        }
    }

    private func trackpadSwipe(_ event: NSEvent) {
        if event.phase.contains(.began) {
            swipeDistance = 0
            swipeConsumed = false
        }
        guard event.momentumPhase.isEmpty, !swipeConsumed else { return }
        swipeDistance += event.scrollingDeltaX
        if abs(swipeDistance) > 60 {
            swipeConsumed = true
            viewer?.navigate(swipeDistance < 0 ? .next : .previous)
        }
    }
}

/// Keeps the image centred whenever it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = frame.midX - rect.width / 2 }
        if rect.height > frame.height { rect.origin.y = frame.midY - rect.height / 2 }
        return rect
    }
}

/// The document view: one layer whose contents is a pre-decoded IOSurface. Its frame is the
/// source's pixel size, so zooming is purely a GPU transform and the contents can be
/// swapped for a sharper decode without any geometry change.
final class ImageCanvasView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    /// An IOSurface for decoded stills, a CGImage for animation frames.
    func setContents(_ contents: Any?) {
        layer?.contents = contents
    }

    /// Nearest-neighbour once each source pixel covers several screen pixels, for pixel peeping.
    func setPixelated(_ pixelated: Bool) {
        let filter: CALayerContentsFilter = pixelated ? .nearest : .linear
        if layer?.magnificationFilter != filter { layer?.magnificationFilter = filter }
    }
}

/// Display-synchronised zoom animation. Interpolates in log space so every frame
/// changes the scale by the same ratio, which reads as constant speed.
@MainActor
final class MagnificationAnimation: NSObject {
    private weak var scrollView: NSScrollView?
    private let from: CGFloat
    private let to: CGFloat
    private let point: NSPoint
    private let duration: CFTimeInterval
    private let completion: () -> Void
    private var startTime: CFTimeInterval?
    private var link: CADisplayLink?

    init(scrollView: NSScrollView, to target: CGFloat, around point: NSPoint, duration: CFTimeInterval = 0.26, completion: @escaping () -> Void) {
        self.scrollView = scrollView
        self.from = scrollView.magnification
        self.to = target
        self.point = point
        self.duration = duration
        self.completion = completion
        super.init()
        let link = scrollView.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { return stop() }
        let start = startTime ?? link.timestamp
        startTime = start
        let progress = min(1, (link.targetTimestamp - start) / duration)
        let eased = 1 - pow(1 - progress, 3)
        scrollView.setMagnification(from * pow(to / from, eased), centeredAt: point)
        if progress >= 1 {
            stop()
            completion()
        }
    }
}
