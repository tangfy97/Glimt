import Foundation
import os

/// Decodes images off the main thread, caches them by byte cost, and keeps exactly the
/// work the viewer currently wants in flight. Everything here runs on the main actor
/// except the decode closures themselves.
@MainActor
final class DecodePipeline {
    struct Key: Hashable, Sendable {
        let url: URL
        let level: DecodeLevel
    }

    struct Request {
        let key: Key
        let priority: Operation.QueuePriority
    }

    /// Called on the main actor; `nil` means the file could not be decoded.
    /// Not called when a `.quick` request finds no embedded thumbnail.
    var onResult: ((Key, DecodedImage?) -> Void)?

    /// The preview rung is sized to this. Changing it drops cached previews.
    var screenPixels = CGSize(width: 2560, height: 1600) {
        didSet {
            guard screenPixels != oldValue else { return }
            cache.removeAll { $0.level == .preview }
        }
    }

    private let queues: [DecodeLevel: OperationQueue]
    private var inFlight: [Key: (operation: Operation, flag: CancelFlag)] = [:]
    private var cache: ByteLimitedCache<Key, DecodedImage>
    private var pinned: Set<Key> = []
    private var failed: Set<URL> = []
    private var withoutThumbnail: Set<URL> = []
    private var pressureSource: DispatchSourceMemoryPressure?

    init() {
        func queue(_ name: String, width: Int, qos: QualityOfService) -> OperationQueue {
            let queue = OperationQueue()
            queue.name = "Glimt.decode.\(name)"
            queue.maxConcurrentOperationCount = width
            queue.qualityOfService = qos
            return queue
        }
        queues = [
            .quick: queue("quick", width: 2, qos: .userInteractive),
            .preview: queue("preview", width: 2, qos: .userInitiated),
            .full: queue("full", width: 1, qos: .userInitiated),
        ]
        let physical = ProcessInfo.processInfo.physicalMemory
        let budget = min(max(physical / 16, 192 << 20), 512 << 20)
        cache = ByteLimitedCache(budget: Int(budget))

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.releaseUnpinned() }
        }
        source.resume()
        pressureSource = source
    }

    func image(for url: URL, level: DecodeLevel) -> DecodedImage? {
        cache.value(for: Key(url: url, level: level))
    }

    /// The sharpest decode available right now.
    func best(for url: URL) -> (image: DecodedImage, level: DecodeLevel)? {
        for level in [DecodeLevel.full, .preview, .quick] {
            if let image = cache.value(for: Key(url: url, level: level)) { return (image, level) }
        }
        return nil
    }

    func contains(_ url: URL, _ level: DecodeLevel) -> Bool {
        cache.contains(Key(url: url, level: level))
    }

    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    /// Makes `requests` the complete set of wanted decodes: starts what is missing,
    /// re-prioritises what is queued, and cancels everything else (e.g. images the
    /// user already paged past). Wanted keys are also protected from eviction.
    func setWanted(_ requests: [Request]) {
        let keys = Set(requests.map(\.key))
        pinned = keys
        for (key, entry) in inFlight where !keys.contains(key) {
            entry.operation.cancel()
            entry.flag.cancel()
            inFlight[key] = nil
        }
        for request in requests {
            if let entry = inFlight[request.key] {
                entry.operation.queuePriority = request.priority
                continue
            }
            guard !cache.contains(request.key), !failed.contains(request.key.url),
                  request.key.level != .quick || !withoutThumbnail.contains(request.key.url) else { continue }
            start(request)
        }
    }

    private func start(_ request: Request) {
        let key = request.key
        let screen = screenPixels
        let flag = CancelFlag()
        let operation = BlockOperation { [self] in
            guard !flag.isCancelled else { return }
            let signposter = Signposts.signposter
            let state = signposter.beginInterval("Decode", id: signposter.makeSignpostID(), "\(key.level.description, privacy: .public)")
            let image = ImageDecoder.decode(key.url, level: key.level, screenPixels: screen)
            signposter.endInterval("Decode", state)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key, image, flag) }
            }
        }
        operation.queuePriority = request.priority
        inFlight[key] = (operation, flag)
        queues[key.level]?.addOperation(operation)
    }

    private func finish(_ key: Key, _ image: DecodedImage?, _ flag: CancelFlag) {
        if inFlight[key]?.flag === flag { inFlight[key] = nil }
        guard let image else {
            if key.level == .quick {
                withoutThumbnail.insert(key.url)
                return
            }
            failed.insert(key.url)
            onResult?(key, nil)
            return
        }
        // Keep finished work even if it was cancelled mid-decode: the user may come back.
        cache.insert(image, for: key, cost: image.byteCost)
        cache.evict(toFit: cache.budget, keeping: pinned)
        onResult?(key, image)
    }

    private func releaseUnpinned() {
        cache.evict(toFit: 0, keeping: pinned)
    }
}

/// Least-recently-used cache that accounts in bytes rather than entries.
struct ByteLimitedCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var lastUse: UInt64
    }

    let budget: Int
    private(set) var totalCost = 0
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(budget: Int) { self.budget = budget }

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    mutating func value(for key: Key) -> Value? {
        guard entries[key] != nil else { return nil }
        clock += 1
        entries[key]!.lastUse = clock
        return entries[key]!.value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        clock += 1
        entries[key] = Entry(value: value, cost: cost, lastUse: clock)
        totalCost += cost
    }

    mutating func remove(_ key: Key) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in entries.keys where shouldRemove(key) { remove(key) }
    }

    mutating func evict(toFit limit: Int, keeping pinned: Set<Key>) {
        guard totalCost > limit else { return }
        let candidates = entries.filter { !pinned.contains($0.key) }.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, _) in candidates where totalCost > limit { remove(key) }
    }
}

final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}
