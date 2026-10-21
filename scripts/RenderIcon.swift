// Renders an icon SVG (1024 canvas, 824 pt body per Apple's macOS grid) into the app's
// AppIcon.appiconset, adding the standard soft drop shadow. Run via scripts/make-icon.sh.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let artwork = NSImage(contentsOfFile: arguments[1]) else {
    print("usage: render-icon <icon.svg> <AppIcon.appiconset>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) throws -> String {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    if pixels >= 64 {
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
        shadow.shadowBlurRadius = 22 * scale
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.set()
    }
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(pixels).png"
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    return name
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = try render(points * scale)
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")
