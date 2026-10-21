import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

/// How sharp a decode is. Each image climbs this ladder; the viewer always shows
/// the best rung it has and never steps down while the same image is on screen.
enum DecodeLevel: Int, Comparable, Sendable, CustomStringConvertible {
    /// The embedded EXIF/HEIC thumbnail only, never a real decode (which would be no faster
    /// than `.preview`). A few ms; files without one simply skip this rung.
    case quick
    /// Aspect-fit to the screen's pixels: enough for fit-to-window and full screen.
    case preview
    /// Native resolution (capped, see `ImageDecoder.fullPixelBudget`), for zooming in.
    case full

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .quick: "quick"
        case .preview: "preview"
        case .full: "full"
        }
    }
}

/// A decoded bitmap in an IOSurface. Core Animation displays IOSurfaces without copying
/// them, so presenting one costs nothing on the main thread and the cache holds the only copy.
struct DecodedImage: @unchecked Sendable {
    let surface: IOSurface
    /// The source's oriented pixel size, whatever resolution this particular decode is.
    let sourceSize: CGSize
    /// More than one for animated GIF, PNG, WebP and HEIC sequences.
    var frameCount = 1

    var longestSide: Int { max(surface.width, surface.height) }
    var byteCost: Int { surface.allocationSize }
}

enum ImageDecoder {
    static let quickMaxPixelSize: CGFloat = 384
    /// Single-texture ceiling for the full rung (~256 MB as BGRA, and within the GPU's
    /// 16384 px texture limit). Larger sources are downsampled to this until tiling lands.
    static let fullPixelBudget: CGFloat = 64_000_000
    static let maxTextureSide: CGFloat = 16_384

    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    nonisolated(unsafe) private static let colorSpaceTag = colorSpace.copyPropertyList()

    /// Longest side a `.full` decode of a source this size will produce.
    static func fullLongestSide(for sourceSize: CGSize) -> Int {
        let pixels = sourceSize.width * sourceSize.height
        guard pixels > 0 else { return 0 }
        let longest = max(sourceSize.width, sourceSize.height)
        let scale = min(1, (fullPixelBudget / pixels).squareRoot(), maxTextureSide / longest)
        return Int((longest * scale).rounded(.down))
    }

    static func decode(_ url: URL, level: DecodeLevel, screenPixels: CGSize) -> DecodedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let size = orientedSize(of: source) else { return nil }

        let longest = max(size.width, size.height)
        let target: CGFloat
        switch level {
        case .quick:
            target = min(longest, quickMaxPixelSize)
        case .preview:
            let scale = min(screenPixels.width / size.width, screenPixels.height / size.height, 1)
            target = (longest * scale).rounded(.up)
        case .full:
            target = CGFloat(fullLongestSide(for: size))
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(target, 1)),
        ]
        if level == .quick || (level == .preview && isRaw(source)) {
            // Embedded thumbnail only. Both flags must be false explicitly: left unset, ImageIO
            // quietly decodes the whole image to make a thumbnail, which defeats the quick rung.
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
            options[kCGImageSourceCreateThumbnailFromImageAlways] = false
        }
        var image: CGImage?
        if level == .preview, isRaw(source) {
            // Like Photo Mechanic: a RAW file's embedded JPEG preview is usually large enough for
            // the screen and costs a fraction of demosaicing. The full rung still decodes the RAW.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            if let embedded = image, CGFloat(max(embedded.width, embedded.height)) < target * 0.6 { image = nil }
        }
        if level == .quick {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else if image == nil {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image, let surface = makeSurface(from: image) else { return nil }
        return DecodedImage(surface: surface, sourceSize: size, frameCount: CGImageSourceGetCount(source))
    }

    private static func isRaw(_ source: CGImageSource) -> Bool {
        guard let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    static func orientedSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5–8 rotate by 90°.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Draws into a BGRA Display P3 surface, which also normalises 16-bit, CMYK and indexed
    /// sources so the render server never has to convert anything.
    static func makeSurface(from image: CGImage) -> IOSurface? {
        let width = image.width, height = image.height
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
            .pixelFormat: 0x4247_5241, // 'BGRA'
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let colorSpaceTag {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpaceTag)
        }
        return surface
    }
}
