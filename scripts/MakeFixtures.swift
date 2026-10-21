// Generates stress-test images for Glimt. Build and run via scripts/make-fixtures.sh.
//
//   photos/  40 numbered 24 MP JPEGs, two 50 MP JPEGs, an EXIF-rotated image,
//            a 16-bit PNG, a tiny PNG and a corrupt file
//   10k/     one 24 MP JPEG cloned 10,000 times (APFS clones: no extra disk use)

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".fixtures")
let fileManager = FileManager.default

struct XorShift {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

func makeImage(width: Int, height: Int, hue: CGFloat, label: String, bitsPerComponent: Int = 8) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = bitsPerComponent == 16
        ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!

    // Diagonal gradient in two hues.
    func color(_ h: CGFloat, _ b: CGFloat) -> CGColor {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let (p, q, t): (CGFloat, CGFloat, CGFloat) = (b * 0.35, b * (1 - 0.65 * f), b * (1 - 0.65 * (1 - f)))
        let rgb: (CGFloat, CGFloat, CGFloat) = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i]
        return CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    let gradient = CGGradient(colorsSpace: space, colors: [color(hue, 0.85), color((hue + 0.18).truncatingRemainder(dividingBy: 1), 0.35)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

    // Fine grid so zooming in shows real detail.
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    context.setLineWidth(1)
    for x in stride(from: 0, to: width, by: 64) { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height)) }
    for y in stride(from: 0, to: height, by: 64) { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y)) }
    context.strokePath()

    // Big label in the middle.
    let fontSize = CGFloat(min(width, height)) * 0.32
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.92)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
    let bounds = CTLineGetImageBounds(line, context)
    context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, context)

    // Sensor-like noise so JPEG decode cost resembles a real photo.
    if bitsPerComponent == 8, let data = context.data {
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var rng = XorShift(state: 0x9E3779B97F4A7C15 &+ UInt64(width * height) &+ UInt64(hue * 1000))
        for row in 0..<height {
            let base = row * context.bytesPerRow
            var x = 0
            while x < width * 4 {
                let r = rng.next()
                for c in 0..<3 {
                    let noise = Int((r >> (c * 8)) & 0x1F) - 16
                    let index = base + x + c
                    bytes[index] = UInt8(clamping: Int(bytes[index]) + noise)
                }
                x += 4
            }
        }
    }
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var options = properties
    options[kCGImageDestinationLossyCompressionQuality] = 0.88
    // Cameras and phones embed a small preview; Glimt shows it while paging fast.
    options[kCGImageDestinationEmbedThumbnail] = true
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "failed to write \(url.path)")
}

let photos = root.appendingPathComponent("photos")
let tenK = root.appendingPathComponent("10k")
try? fileManager.removeItem(at: root)
try fileManager.createDirectory(at: photos, withIntermediateDirectories: true)
try fileManager.createDirectory(at: tenK, withIntermediateDirectories: true)

for i in 1...40 {
    let image = makeImage(width: 6000, height: 4000, hue: CGFloat(i) / 40, label: "\(i)")
    write(image, to: photos.appendingPathComponent(String(format: "IMG_%04d.jpg", i)), type: .jpeg)
    if i == 1 { write(image, to: tenK.appendingPathComponent("seed.jpg"), type: .jpeg) }
}
for i in 1...2 {
    let image = makeImage(width: 8640, height: 5760, hue: 0.55 + CGFloat(i) * 0.1, label: "50MP \(i)")
    write(image, to: photos.appendingPathComponent("IMG_9\(i)00_50MP.jpg"), type: .jpeg)
}
write(makeImage(width: 4000, height: 3000, hue: 0.3, label: "↑ up"), to: photos.appendingPathComponent("IMG_9300_rotated.jpg"),
      type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
write(makeImage(width: 3000, height: 2000, hue: 0.8, label: "16-bit", bitsPerComponent: 16), to: photos.appendingPathComponent("IMG_9400_16bit.png"), type: .png)
write(makeImage(width: 400, height: 300, hue: 0.1, label: "tiny"), to: photos.appendingPathComponent("IMG_9500_tiny.png"), type: .png)
try Data("definitely not a jpeg".utf8).write(to: photos.appendingPathComponent("IMG_9600_corrupt.jpg"))

let seed = tenK.appendingPathComponent("seed.jpg")
for i in 1...10_000 {
    let target = tenK.appendingPathComponent(String(format: "DSC_%05d.jpg", i))
    guard clonefile(seed.path, target.path, 0) == 0 else { fatalError("clonefile failed: \(errno)") }
}
try fileManager.removeItem(at: seed)
print("Fixtures written to \(root.path)")
