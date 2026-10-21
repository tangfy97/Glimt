import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Thumbnail: Sendable {
    let image: DecodedImage
    /// Seconds, for videos.
    let duration: Double?
}

/// Grid thumbnails in three sizes (256, 512, 1024 px), cached in memory by byte cost and on
/// disk in ~/Library/Caches so a folder seen once opens instantly afterwards.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    static let sizes = [256, 512, 1024]

    final class Token {}

    private struct Key: Hashable {
        let url: URL
        let pixels: Int
    }

    private var memory = ByteLimitedCache<Key, Thumbnail>(budget: 160 << 20)
    private var waiters: [Key: [(token: Token, deliver: (Thumbnail) -> Void)]] = [:]
    private var inFlight: [Key: (operation: Operation, flag: CancelFlag)] = [:]
    private var failed: Set<Key> = []
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Glimt.thumbnails"
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        queue.qualityOfService = .userInitiated
        return queue
    }()

    nonisolated static let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(AppInfo.identifier, isDirectory: true).appendingPathComponent("Thumbnails", isDirectory: true)
    }()

    static func pixels(forPoints points: CGFloat, scale: CGFloat) -> Int {
        sizes.first { CGFloat($0) >= points * scale * 0.9 } ?? 1024
    }

    /// Exact size if cached, otherwise any cached size (to show while the right one loads).
    func cached(_ url: URL, pixels: Int) -> (thumbnail: Thumbnail, exact: Bool)? {
        if let exact = memory.value(for: Key(url: url, pixels: pixels)) { return (exact, true) }
        for size in Self.sizes where size != pixels {
            if let other = memory.value(for: Key(url: url, pixels: size)) { return (other, false) }
        }
        return nil
    }

    /// Delivers on the main actor. Returns a token for `cancel`, or nil if nothing is pending.
    @discardableResult
    func request(_ item: Item, pixels: Int, priority: Operation.QueuePriority = .normal,
                 deliver: @escaping (Thumbnail) -> Void) -> Token? {
        let key = Key(url: item.url, pixels: pixels)
        if let thumbnail = memory.value(for: key) {
            deliver(thumbnail)
            return nil
        }
        guard !failed.contains(key) else { return nil }
        let token = Token()
        waiters[key, default: []].append((token, deliver))
        if let entry = inFlight[key] {
            if priority.rawValue > entry.operation.queuePriority.rawValue { entry.operation.queuePriority = priority }
            return token
        }
        let flag = CancelFlag()
        let isVideo = item.kind == .video
        let modified = item.modified
        let operation = BlockOperation { [self] in
            guard !flag.isCancelled else { return }
            let thumbnail = Self.produce(key.url, isVideo: isVideo, modified: modified, pixels: pixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key, thumbnail, flag) }
            }
        }
        operation.queuePriority = priority
        inFlight[key] = (operation, flag)
        queue.addOperation(operation)
        return token
    }

    func cancel(_ token: Token?) {
        guard let token else { return }
        for (key, list) in waiters where list.contains(where: { $0.token === token }) {
            let remaining = list.filter { $0.token !== token }
            waiters[key] = remaining.isEmpty ? nil : remaining
            if remaining.isEmpty, let entry = inFlight.removeValue(forKey: key) {
                entry.operation.cancel()
                entry.flag.cancel()
            }
            return
        }
    }

    func invalidate(_ url: URL) {
        for size in Self.sizes {
            let key = Key(url: url, pixels: size)
            memory.remove(key)
            failed.remove(key)
        }
    }

    private func finish(_ key: Key, _ thumbnail: Thumbnail?, _ flag: CancelFlag) {
        if inFlight[key]?.flag === flag { inFlight[key] = nil }
        let list = waiters.removeValue(forKey: key) ?? []
        guard let thumbnail else {
            failed.insert(key)
            return
        }
        memory.insert(thumbnail, for: key, cost: thumbnail.image.byteCost)
        memory.evict(toFit: memory.budget, keeping: [])
        for waiter in list { waiter.deliver(thumbnail) }
    }

    // MARK: - Disk cache

    static func diskUsage() async -> Int64 {
        await Task.detached(priority: .utility) { measureDiskUsage() }.value
    }

    nonisolated private static func measureDiskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func clearDiskCache() {
        memory.removeAll { _ in true }
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    nonisolated private static func diskURL(for url: URL, modified: Date, pixels: Int) -> URL {
        // FNV-1a over path, modification time and size: a changed file gets a new entry.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(url.path)|\(modified.timeIntervalSince1970)|\(pixels)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        let name = String(format: "%016llx", hash)
        return cacheDirectory.appendingPathComponent(String(name.prefix(2)), isDirectory: true).appendingPathComponent(name)
    }

    nonisolated private static func produce(_ url: URL, isVideo: Bool, modified: Date, pixels: Int) -> Thumbnail? {
        let cacheURL = diskURL(for: url, modified: modified, pixels: pixels)
        if let cached = readCached(cacheURL) { return cached }

        let generated: (CGImage, CGSize, Double?)?
        if isVideo {
            generated = videoFrame(url, pixels: pixels)
        } else {
            generated = imageThumbnail(url, pixels: pixels)
        }
        guard let (image, sourceSize, duration) = generated, let surface = ImageDecoder.makeSurface(from: image) else { return nil }
        writeCached(image, sourceSize: sourceSize, duration: duration, to: cacheURL)
        return Thumbnail(image: DecodedImage(surface: surface, sourceSize: sourceSize), duration: duration)
    }

    nonisolated private static func imageThumbnail(_ url: URL, pixels: Int) -> (CGImage, CGSize, Double?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = ImageDecoder.orientedSize(of: source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(pixels, Int(max(size.width, size.height))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, size, nil)
    }

    nonisolated private static func videoFrame(_ url: URL, pixels: Int) -> (CGImage, CGSize, Double?)? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        let result = ResultBox<(CGImage, Double?)>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let duration = try? await asset.load(.duration).seconds
            let time = CMTime(seconds: min(1, (duration ?? 0) / 3), preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                result.set((image, duration))
            }
            done.signal()
        }
        done.wait()
        guard let (image, duration) = result.get() else { return nil }
        return (image, CGSize(width: image.width, height: image.height), duration)
    }

    nonisolated private static func readCached(_ file: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let description = storedDescription(in: properties)
        else { return nil }
        // "glimt;<width>;<height>;<duration or empty>"
        let fields = description.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "glimt", let width = Double(fields[1]), let height = Double(fields[2]),
              let surface = ImageDecoder.makeSurface(from: image) else { return nil }
        return Thumbnail(image: DecodedImage(surface: surface, sourceSize: CGSize(width: width, height: height)), duration: Double(fields[3]))
    }

    /// ImageIO writes the TIFF ImageDescription but may read it back as the IPTC caption
    /// (JPEG) or the PNG description, so look in all three.
    nonisolated private static func storedDescription(in properties: [CFString: Any]) -> String? {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let candidates = [tiff?[kCGImagePropertyTIFFImageDescription], iptc?[kCGImagePropertyIPTCCaptionAbstract], png?[kCGImagePropertyPNGDescription]]
        return candidates.lazy.compactMap { $0 as? String }.first { $0.hasPrefix("glimt;") }
    }

    nonisolated private static func writeCached(_ image: CGImage, sourceSize: CGSize, duration: Double?, to file: URL) {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = hasAlpha ? UTType.png : UTType.jpeg
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.appendingPathExtension("tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else { return }
        let description = "glimt;\(Int(sourceSize.width));\(Int(sourceSize.height));\(duration.map { String($0) } ?? "")"
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description],
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        if CGImageDestinationFinalize(destination) {
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: temporary)
            if !FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.moveItem(at: temporary, to: file) }
        }
    }
}

/// A value handed from an async task back to a waiting thread.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func get() -> T? { lock.withLock { value } }
}
