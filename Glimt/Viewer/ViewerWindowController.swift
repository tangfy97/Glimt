import AppKit
import os

/// Owns one folder's worth of state: the file list, the current position, and the decode
/// pipeline. Decides what to decode next and hands finished bitmaps to the view.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    var onOpenedURL: ((URL) -> Void)?
    /// Hooks for the benchmark harness.
    var onItemsLoaded: ((_ count: Int, _ scanMilliseconds: Double) -> Void)?
    var onImageShown: ((URL, DecodeLevel) -> Void)?

    private let viewer = ViewerView()
    private let pipeline = DecodePipeline()

    private var folder: URL?
    private(set) var items: [URL] = []
    private(set) var index = 0
    private var direction = 1
    private var lastTurn: CFTimeInterval = 0
    /// Key repeat or a fast hand: turns closer together than decodes take.
    private var isRapidPaging = false
    private var shown: (url: URL, level: DecodeLevel, sourceSize: CGSize)?
    private var deferredUpgrade: (key: DecodePipeline.Key, image: DecodedImage)?
    private var wantsFullResolution = false
    private var scanTask: Task<Void, Never>?
    private var pageTurn: OSSignpostIntervalState?

    var currentURL: URL? { items.indices.contains(index) ? items[index] : nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Glimt"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.background
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 260)
        window.isReleasedWhenClosed = false
        window.contentView = viewer
        super.init(window: window)

        window.delegate = self
        if !window.setFrameUsingName("Viewer") { window.center() }
        window.setFrameAutosaveName("Viewer")
        viewer.delegate = self
        pipeline.onResult = { [weak self] key, image in self?.decodeFinished(key, image) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Opening

    /// Opens a folder, or an image together with the rest of its folder.
    func open(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        let startName = isDirectory ? nil : url.lastPathComponent
        self.folder = folder
        onOpenedURL?(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        if isDirectory {
            setItems([], index: 0, placeholder: .loading)
        } else {
            // Start decoding the chosen image while the folder is still being listed.
            setItems([url], index: 0)
        }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let started = CACurrentMediaTime()
            let urls = await FolderScanner.imageURLs(in: folder)
            guard let self, !Task.isCancelled else { return }
            let start = startName.flatMap { name in urls.firstIndex { $0.lastPathComponent == name } } ?? 0
            self.setItems(urls, index: start)
            self.onItemsLoaded?(urls.count, (CACurrentMediaTime() - started) * 1000)
        }
    }

    private func setItems(_ urls: [URL], index: Int, placeholder: PlaceholderView.Content? = nil) {
        items = urls
        self.index = min(max(index, 0), max(urls.count - 1, 0))
        if urls.isEmpty {
            shown = nil
            pipeline.setWanted([])
            viewer.showPlaceholder(placeholder ?? .noImages(folder: folder?.lastPathComponent ?? ""))
            updateTitle()
            return
        }
        showCurrent()
    }

    // MARK: - Navigation

    func navigate(_ navigation: Navigation) {
        guard !items.isEmpty else { return }
        let target: Int
        switch navigation {
        case .next: target = index + 1
        case .previous: target = index - 1
        case .first: target = 0
        case .last: target = items.count - 1
        }
        guard items.indices.contains(target), target != index else {
            viewer.flashMessage(navigation == .next || navigation == .last
                ? String(localized: "Last image") : String(localized: "First image"))
            return
        }
        direction = target > index ? 1 : -1
        index = target
        let now = CACurrentMediaTime()
        isRapidPaging = now - lastTurn < 0.15
        lastTurn = now
        if isRapidPaging { settleRapidPagingSoon(after: now) }
        if let pageTurn { Signposts.signposter.endInterval("Page Turn", pageTurn) }
        pageTurn = Signposts.signposter.beginInterval("Page Turn", id: Signposts.signposter.makeSignpostID())
        if window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
        showCurrent()
    }

    private func showCurrent() {
        guard let url = currentURL else { return }
        if shown?.url != url {
            wantsFullResolution = false
            deferredUpgrade = nil
            if let best = pipeline.best(for: url) {
                present(best.image, level: best.level, url: url)
            } else if pipeline.hasFailed(url) {
                showUnreadable(url)
            } else if isRapidPaging {
                shown = nil
                viewer.clearImage()
            }
            // Otherwise the previous image stays up for the few ms until a decode lands.
        }
        updateTitle()
        scheduleDecodes()
    }

    /// The wanted set, in priority order: the current image (fast thumbnail, then screen-sized,
    /// then full if zoomed), then neighbours biased towards the direction of travel.
    private func scheduleDecodes() {
        guard let url = currentURL else { return pipeline.setWanted([]) }
        if let screen = window?.screen ?? NSScreen.main {
            let scale = screen.backingScaleFactor
            pipeline.screenPixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        }

        typealias Request = DecodePipeline.Request
        var requests: [Request] = []
        if !pipeline.contains(url, .preview) && !pipeline.contains(url, .full) {
            requests.append(Request(key: .init(url: url, level: .quick), priority: .veryHigh))
        }
        requests.append(Request(key: .init(url: url, level: .preview), priority: .veryHigh))
        if wantsFullResolution {
            requests.append(Request(key: .init(url: url, level: .full), priority: .veryHigh))
        }
        if isRapidPaging {
            // Embedded thumbnails are nearly free; run well ahead so something is always ready.
            for offset in 1...8 {
                let ahead = index + offset * direction
                guard items.indices.contains(ahead) else { break }
                requests.append(Request(key: .init(url: items[ahead], level: .quick), priority: .high))
            }
            for offset in 1...2 {
                let ahead = index + offset * direction
                guard items.indices.contains(ahead) else { break }
                requests.append(Request(key: .init(url: items[ahead], level: .preview), priority: .normal))
            }
        } else {
            let neighbours: [(Int, Operation.QueuePriority)] = [(1, .high), (-1, .normal), (2, .normal), (3, .low), (-2, .low)]
            for (offset, priority) in neighbours {
                let neighbour = index + offset * direction
                guard items.indices.contains(neighbour) else { continue }
                requests.append(Request(key: .init(url: items[neighbour], level: .preview), priority: priority))
            }
        }
        pipeline.setWanted(requests)
    }

    /// Once the keys go quiet, switch back to normal prefetching around the resting image.
    private func settleRapidPagingSoon(after turn: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.lastTurn == turn else { return }
                self.isRapidPaging = false
                self.scheduleDecodes()
            }
        }
    }

    private func decodeFinished(_ key: DecodePipeline.Key, _ image: DecodedImage?) {
        guard key.url == currentURL else { return }
        guard let image else {
            if shown?.url != key.url { showUnreadable(key.url) }
            return
        }
        if let shown, shown.url == key.url, shown.level >= key.level { return }
        if viewer.isLiveMagnifying, shown?.url == key.url {
            // Swapping a large texture mid-pinch could cost a frame; do it when the fingers lift.
            deferredUpgrade = (key, image)
            return
        }
        present(image, level: key.level, url: key.url)
    }

    private func present(_ image: DecodedImage, level: DecodeLevel, url: URL) {
        let isNewImage = shown?.url != url
        shown = (url, level, image.sourceSize)
        viewer.display(image, resetZoom: isNewImage)
        if isNewImage {
            updateTitle()
            if let pageTurn {
                Signposts.signposter.endInterval("Page Turn", pageTurn)
                self.pageTurn = nil
            }
        }
        onImageShown?(url, level)
    }

    private func showUnreadable(_ url: URL) {
        shown = nil
        viewer.showPlaceholder(.unreadable(file: url.lastPathComponent))
    }

    private func updateTitle() {
        guard let window else { return }
        guard let url = currentURL else {
            window.title = folder?.lastPathComponent ?? "Glimt"
            window.subtitle = ""
            return
        }
        window.title = url.lastPathComponent
        var subtitle = "\(index + 1) / \(items.count)"
        if let shown, shown.url == url {
            subtitle += "  ·  \(Int(shown.sourceSize.width)) × \(Int(shown.sourceSize.height))"
        }
        window.subtitle = subtitle
    }

    func isCached(_ url: URL) -> Bool {
        pipeline.contains(url, .preview) || pipeline.contains(url, .full)
    }

    // MARK: - Actions

    @objc func nextImage(_ sender: Any?) { navigate(.next) }
    @objc func previousImage(_ sender: Any?) { navigate(.previous) }
    @objc func firstImage(_ sender: Any?) { navigate(.first) }
    @objc func lastImage(_ sender: Any?) { navigate(.last) }
    @objc func zoomIn(_ sender: Any?) { viewer.zoom(by: 1.5) }
    @objc func zoomOut(_ sender: Any?) { viewer.zoom(by: 1 / 1.5) }
    @objc func zoomToActualSize(_ sender: Any?) { viewer.zoomToActualSize() }
    @objc func zoomToFit(_ sender: Any?) { viewer.zoomToFit() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(nextImage(_:)), #selector(lastImage(_:)):
            return index + 1 < items.count
        case #selector(previousImage(_:)), #selector(firstImage(_:)):
            return index > 0 && !items.isEmpty
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomToActualSize(_:)), #selector(zoomToFit(_:)):
            return viewer.hasImage
        default:
            return true
        }
    }

    // MARK: - Window

    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.backgroundColor = Palette.fullScreenBackground
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.backgroundColor = Palette.background
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleDecodes()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        scheduleDecodes()
    }
}

extension ViewerWindowController: ViewerViewDelegate {
    func viewer(_ viewer: ViewerView, navigate navigation: Navigation) {
        navigate(navigation)
    }

    func viewerWantsDetail(_ viewer: ViewerView) {
        guard !wantsFullResolution, viewer.isShowingReducedResolution else { return }
        wantsFullResolution = true
        scheduleDecodes()
    }

    func viewerDidSettleZoom(_ viewer: ViewerView) {
        if let upgrade = deferredUpgrade {
            deferredUpgrade = nil
            decodeFinished(upgrade.key, upgrade.image)
        }
        // Back at fit, the screen-sized decode looks better (no minification aliasing)
        // and lets the much larger full decode leave the pinned set.
        guard viewer.isFitMode, let url = currentURL, let shown, shown.url == url, shown.level == .full,
              let preview = pipeline.image(for: url, level: .preview) else { return }
        wantsFullResolution = false
        present(preview, level: .preview, url: url)
        scheduleDecodes()
    }

    func viewer(_ viewer: ViewerView, open url: URL) {
        open(url)
    }
}
