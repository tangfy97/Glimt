import AppKit
import os

@MainActor
protocol ViewerControllerDelegate: AnyObject {
    /// The current item changed (or its decode arrived): update title, inspector, selection.
    func viewerController(_ viewer: ViewerController, didShow item: Item?)
    func viewerControllerWantsClose(_ viewer: ViewerController)
    func viewerController(_ viewer: ViewerController, open url: URL)
    func viewerController(_ viewer: ViewerController, slideshowDidChange running: Bool)
}

/// Single-image viewing over the folder model's media list: picks what to decode next,
/// hands finished bitmaps to the view, plays video and animation, runs the slideshow.
@MainActor
final class ViewerController: NSObject {
    weak var delegate: ViewerControllerDelegate?
    /// Benchmark hook.
    var onImageShown: ((URL, DecodeLevel) -> Void)?

    let view = ViewerView()
    private let model: FolderModel
    private let pipeline = DecodePipeline()

    private(set) var index = 0
    private(set) var isActive = false
    private var currentURL: URL?
    private var direction = 1
    private var lastTurn: CFTimeInterval = 0
    /// Key repeat or a fast hand: turns closer together than decodes take.
    private var isRapidPaging = false
    private(set) var shown: (url: URL, level: DecodeLevel, sourceSize: CGSize)?
    private var deferredUpgrade: (key: DecodePipeline.Key, image: DecodedImage)?
    private var wantsFullResolution = false
    private var pageTurn: OSSignpostIntervalState?
    private var animation: AnimatedImagePlayer?

    private var slideshowTask: Task<Void, Never>?
    private(set) var isSlideshowPaused = false
    var isSlideshowRunning: Bool { slideshowTask != nil }
    /// During a slideshow of a selection, or a shuffled one: the order to play, by URL.
    private var playlist: [URL]?
    private var playlistItems: [Item] = []
    private var infoDetails: [URL: String] = [:]

    init(model: FolderModel) {
        self.model = model
        super.init()
        view.delegate = self
        pipeline.onResult = { [weak self] key, image in self?.decodeFinished(key, image) }
        model.observe { [weak self] change in self?.modelChanged(change) }
    }

    var items: [Item] { playlist == nil ? model.media : playlistItems }
    var currentItem: Item? { items.indices.contains(index) ? items[index] : nil }

    // MARK: - Activation

    func show(index newIndex: Int, seed thumbnail: Thumbnail? = nil) {
        guard items.indices.contains(newIndex) else { return }
        isActive = true
        index = newIndex
        currentURL = items[newIndex].url
        if let thumbnail, let url = currentURL {
            pipeline.seed(thumbnail.image, for: url, level: .quick)
        }
        shown = nil
        showCurrent()
        view.focus()
    }

    func deactivate() {
        isActive = false
        stopSlideshow()
        stopMedia()
        pipeline.setWanted([])
    }

    func reloadCurrent() {
        guard let url = currentURL else { return }
        pipeline.invalidate(url)
        shown = nil
        showCurrent()
    }

    func invalidate(_ url: URL) {
        pipeline.invalidate(url)
        if url == currentURL { reloadCurrent() }
    }

    private func modelChanged(_ change: FolderModel.Change) {
        if case .renamed(let from, let to) = change {
            if from == currentURL { currentURL = to }
            playlist = playlist?.map { $0 == from ? to : $0 }
        }
        rebuildPlaylist()
        guard isActive else { return }
        if items.isEmpty {
            delegate?.viewerControllerWantsClose(self)
            return
        }
        if let url = currentURL, let found = items.firstIndex(where: { $0.url == url }) {
            index = found
        } else {
            // The current file left (sorted away, trashed): show whatever took its place.
            index = min(index, items.count - 1)
            currentURL = items[index].url
        }
        showCurrent()
    }

    // MARK: - Navigation

    func navigate(_ navigation: Navigation) {
        guard isActive, !items.isEmpty else { return }
        var target: Int
        var forward = true
        switch navigation {
        case .next: target = index + 1
        case .previous: target = index - 1; forward = false
        case .first: target = 0; forward = false
        case .last: target = items.count - 1
        case .jump(let offset): target = min(max(index + offset, 0), items.count - 1); forward = offset > 0
        }
        guard items.indices.contains(target), target != index else {
            if isSlideshowRunning, forward, Preferences.slideshowLoops {
                if Preferences.slideshowShuffles { reshuffle() }
                return go(to: 0)
            }
            view.flashMessage(forward ? String(localized: "This is the last one") : String(localized: "This is the first one"))
            return
        }
        target = min(max(target, 0), items.count - 1)
        go(to: target)
    }

    private func go(to target: Int) {
        direction = target >= index ? 1 : -1
        index = target
        currentURL = items[target].url
        let now = CACurrentMediaTime()
        isRapidPaging = now - lastTurn < 0.15
        lastTurn = now
        if isRapidPaging { settleRapidPagingSoon(after: now) }
        if let pageTurn { Signposts.signposter.endInterval("Page Turn", pageTurn) }
        pageTurn = Signposts.signposter.beginInterval("Page Turn", id: Signposts.signposter.makeSignpostID())
        if view.window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
        showCurrent()
    }

    private func showCurrent() {
        guard let item = currentItem else { return }
        let url = item.url
        if item.kind == .video {
            stopMedia()
            shown = nil
            view.showVideo(url)
            delegate?.viewerController(self, didShow: item)
            updateInfo()
            scheduleDecodes()
            return
        }
        if shown?.url != url {
            stopMedia()
            wantsFullResolution = false
            deferredUpgrade = nil
            if let best = pipeline.best(for: url) {
                present(best.image, level: best.level, url: url)
            } else if pipeline.hasFailed(url) {
                showUnreadable(url)
            } else if isRapidPaging || view.isShowingVideo {
                shown = nil
                view.hideVideo()
                view.clearImage()
            }
            // Otherwise the previous image stays up for the few ms until a decode lands.
        }
        delegate?.viewerController(self, didShow: item)
        scheduleDecodes()
    }

    /// The wanted set, in priority order: the current image (embedded thumbnail, screen-sized,
    /// then full if zoomed), then neighbours biased towards the direction of travel.
    private func scheduleDecodes() {
        guard isActive, let item = currentItem else { return pipeline.setWanted([]) }
        if let screen = view.window?.screen ?? NSScreen.main {
            let scale = screen.backingScaleFactor
            pipeline.screenPixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        }

        typealias Request = DecodePipeline.Request
        var requests: [Request] = []
        let url = item.url
        if item.kind == .image {
            if !pipeline.contains(url, .preview) && !pipeline.contains(url, .full) {
                requests.append(Request(key: .init(url: url, level: .quick), priority: .veryHigh))
            }
            requests.append(Request(key: .init(url: url, level: .preview), priority: .veryHigh))
            if wantsFullResolution {
                requests.append(Request(key: .init(url: url, level: .full), priority: .veryHigh))
            }
        }
        func neighbour(_ offset: Int) -> Item? {
            let position = index + offset * direction
            guard items.indices.contains(position), items[position].kind == .image else { return nil }
            return items[position]
        }
        if isRapidPaging {
            // Embedded thumbnails are nearly free; run well ahead so something is always ready.
            for offset in 1...8 {
                if let ahead = neighbour(offset) { requests.append(Request(key: .init(url: ahead.url, level: .quick), priority: .high)) }
            }
            for offset in 1...2 {
                if let ahead = neighbour(offset) { requests.append(Request(key: .init(url: ahead.url, level: .preview), priority: .normal)) }
            }
        } else {
            let neighbours: [(Int, Operation.QueuePriority)] = [(1, .high), (-1, .normal), (2, .normal), (3, .low), (-2, .low)]
            for (offset, priority) in neighbours {
                if let near = neighbour(offset) { requests.append(Request(key: .init(url: near.url, level: .preview), priority: priority)) }
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
        guard isActive, key.url == currentURL else { return }
        guard let image else {
            if shown?.url != key.url { showUnreadable(key.url) }
            return
        }
        if let shown, shown.url == key.url, shown.level >= key.level { return }
        if view.isLiveMagnifying, shown?.url == key.url {
            // Swapping a large texture mid-pinch could cost a frame; do it when the fingers lift.
            deferredUpgrade = (key, image)
            return
        }
        present(image, level: key.level, url: key.url)
    }

    private func present(_ image: DecodedImage, level: DecodeLevel, url: URL) {
        let isNewImage = shown?.url != url
        shown = (url, level, image.sourceSize)
        view.display(image, resetZoom: isNewImage)
        if image.frameCount > 1, level >= .preview, animation?.url != url {
            animation?.stop()
            animation = AnimatedImagePlayer(url: url) { [weak self] frame in
                guard let self, self.currentURL == url else { return }
                self.view.displayAnimationFrame(frame)
            }
        }
        if isNewImage {
            if let item = currentItem { delegate?.viewerController(self, didShow: item) }
            updateInfo()
            if let pageTurn {
                Signposts.signposter.endInterval("Page Turn", pageTurn)
                self.pageTurn = nil
            }
        }
        onImageShown?(url, level)
    }

    private func showUnreadable(_ url: URL) {
        shown = nil
        stopMedia()
        view.showPlaceholder(.unreadable(file: url.lastPathComponent))
    }

    private func stopMedia() {
        animation?.stop()
        animation = nil
        view.hideVideo()
    }

    func isCached(_ url: URL) -> Bool {
        pipeline.contains(url, .preview) || pipeline.contains(url, .full)
    }

    // MARK: - Zoom

    func zoomIn() { view.zoom(by: 1.5) }
    func zoomOut() { view.zoom(by: 1 / 1.5) }
    func zoomToActualSize() { view.zoomToActualSize() }
    func zoomToFit() { view.zoomToFit() }

    // MARK: - Info overlay

    private func updateInfo() {
        let level = Preferences.infoOverlay
        guard level > 0, let item = currentItem else { return view.setInfo(nil) }
        var facts = ["\(index + 1) / \(items.count)"]
        if let shown, shown.url == item.url {
            facts.append("\(Int(shown.sourceSize.width)) × \(Int(shown.sourceSize.height))")
        }
        facts.append(ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
        var lines = [item.name, facts.joined(separator: "   ")]
        if level > 1 {
            if let details = infoDetails[item.url] {
                if !details.isEmpty { lines.append(details) }
            } else {
                Task {
                    let details = await MetadataReader.summary(for: item)
                    self.infoDetails[item.url] = details
                    if self.currentURL == item.url { self.updateInfo() }
                }
            }
        }
        view.setInfo(lines)
    }

    // MARK: - Slideshow

    /// Phoenix Slides' rule: with several images selected, play just those.
    func startSlideshow(only selection: [URL]? = nil) {
        stopSlideshow()
        if let selection, selection.count > 1 {
            playlist = selection
        } else if Preferences.slideshowShuffles {
            playlist = model.media.map(\.url)
        }
        if Preferences.slideshowShuffles { reshuffle() }
        rebuildPlaylist()
        guard !items.isEmpty else { return }
        if let url = currentURL, let found = items.firstIndex(where: { $0.url == url }) {
            index = found
        } else {
            index = 0
            currentURL = items[0].url
            showCurrent()
        }
        isSlideshowPaused = false
        announceInterval()
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(Preferences.slideshowInterval * 1000)))
                guard let self, !Task.isCancelled else { return }
                if self.isSlideshowPaused || self.view.isLiveMagnifying { continue }
                if self.index + 1 >= self.items.count && !Preferences.slideshowLoops {
                    self.stopSlideshow()
                    return
                }
                self.navigate(.next)
            }
        }
        delegate?.viewerController(self, slideshowDidChange: true)
    }

    func stopSlideshow() {
        guard let task = slideshowTask else { return }
        task.cancel()
        slideshowTask = nil
        playlist = nil
        rebuildPlaylist()
        if let url = currentURL, let found = items.firstIndex(where: { $0.url == url }) { index = found }
        delegate?.viewerController(self, slideshowDidChange: false)
    }

    /// Keeps the playing item first so shuffling never jumps away from what is on screen.
    private func reshuffle() {
        guard var order = playlist else { return }
        order.shuffle()
        if let url = currentURL, let position = order.firstIndex(of: url) { order.swapAt(0, position) }
        playlist = order
        rebuildPlaylist()
        index = 0
    }

    private func rebuildPlaylist() {
        guard let playlist else {
            playlistItems = []
            return
        }
        let byURL = Dictionary(model.media.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        playlistItems = playlist.compactMap { byURL[$0] }
    }

    private func announceInterval() {
        let seconds = Preferences.slideshowInterval
        let text = seconds < 1 ? String(format: "%.1f", seconds) : "\(Int(seconds))"
        view.flashMessage(String(localized: "Slideshow, \(text) s per image"))
    }

    func toggleSlideshowPause() {
        isSlideshowPaused.toggle()
        view.flashMessage(isSlideshowPaused ? String(localized: "Paused") : String(localized: "Playing"))
    }

    func cycleInfo() {
        Preferences.infoOverlay = (Preferences.infoOverlay + 1) % 3
        updateInfo()
    }
}

extension ViewerController: ViewerViewDelegate {
    func viewer(_ viewer: ViewerView, navigate navigation: Navigation) {
        navigate(navigation)
    }

    func viewerWantsDetail(_ viewer: ViewerView) {
        guard !wantsFullResolution, animation == nil, viewer.isShowingReducedResolution else { return }
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
        delegate?.viewerController(self, open: url)
    }

    func viewerPressedSpace(_ viewer: ViewerView, shift: Bool) {
        if isSlideshowRunning {
            toggleSlideshowPause()
        } else if viewer.isShowingVideo {
            viewer.toggleVideoPlayback()
        } else {
            navigate(shift ? .previous : .next)
        }
    }

    func viewerCycleInfo(_ viewer: ViewerView) {
        cycleInfo()
    }

    func viewer(_ viewer: ViewerView, adjustSlideshowFaster faster: Bool) {
        let steps: [Double] = [0.5, 1, 1.5, 2, 3, 4, 5, 7, 10, 15, 20, 30]
        let current = Preferences.slideshowInterval
        let next = faster ? steps.last { $0 < current } ?? steps[0] : steps.first { $0 > current } ?? steps[steps.count - 1]
        Preferences.slideshowInterval = next
        announceInterval()
    }

    func viewerPressedEscape(_ viewer: ViewerView) -> Bool {
        if isSlideshowRunning {
            stopSlideshow()
        } else if viewer.hasImage, !viewer.isFitMode {
            viewer.zoomToFit()
        } else {
            delegate?.viewerControllerWantsClose(self)
        }
        return true
    }
}

/// Plays GIF / APNG / WebP / HEIC sequences frame by frame through ImageIO.
@MainActor
final class AnimatedImagePlayer {
    let url: URL
    private let flag = CancelFlag()

    init(url: URL, onFrame: @escaping @MainActor (CGImage) -> Void) {
        self.url = url
        let flag = self.flag
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { _, frame, stop in
            if flag.isCancelled {
                stop.pointee = true
                return
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { onFrame(frame) }
            } else {
                DispatchQueue.main.async { onFrame(frame) }
            }
        }
    }

    func stop() {
        flag.cancel()
    }
}
