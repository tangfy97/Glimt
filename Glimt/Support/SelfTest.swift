import AppKit
import ImageIO
import UniformTypeIdentifiers

/// End-to-end check of every file operation and its undo/redo, against real files in a
/// temporary folder. Run with `GLIMT_SELFTEST=1`; prints PASS/FAIL lines and quits with
/// a non-zero status on failure.
@MainActor
final class SelfTest {
    private let window: MainWindowController
    private var failures = 0
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtSelfTest-\(UUID().uuidString)")
    private var photos: URL { root.appendingPathComponent("photos") }
    private var keep: URL { root.appendingPathComponent("keep") }

    init?(window: MainWindowController) {
        guard ProcessInfo.processInfo.environment["GLIMT_SELFTEST"] != nil else { return nil }
        self.window = window
    }

    func start() {
        Task {
            await run()
            try? FileManager.default.removeItem(at: root)
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func run() async {
        let operations = window.operations
        let undo = operations.undoManager
        undo.groupsByEvent = false
        func step(_ work: () -> Void) {
            undo.beginUndoGrouping()
            work()
            undo.endUndoGrouping()
        }

        do {
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
            for name in ["a.jpg", "b.jpg", "c.jpg"] { try writeImage(photos.appendingPathComponent(name)) }
        } catch {
            check("set up fixtures", false)
            return
        }

        window.open(photos)
        await until("folder loads with 3 images") { self.window.model.media.count == 3 }

        let a = photos.appendingPathComponent("a.jpg")
        let b = photos.appendingPathComponent("b.jpg")
        let c = photos.appendingPathComponent("c.jpg")
        let keptA = keep.appendingPathComponent("a.jpg")

        step { operations.move([a], into: keep) }
        check("move updates the model immediately", window.model.media.count == 2)
        await until("move puts the file in the target") { self.exists(keptA) && !self.exists(a) }
        undo.undo()
        await until("undo move brings it back") { self.exists(a) && !self.exists(keptA) }
        undo.redo()
        await until("redo move sends it again") { self.exists(keptA) && !self.exists(a) }
        undo.undo()
        await until("undo again") { self.exists(a) }

        step { operations.copy([a], into: keep) }
        await until("copy leaves the original") { self.exists(keptA) && self.exists(a) }
        undo.undo()
        await until("undo copy removes the copy") { !self.exists(keptA) && self.exists(a) }

        step { operations.trash([b]) }
        await until("trash removes the file") { !self.exists(b) }
        undo.undo()
        await until("undo trash restores it") { self.exists(b) }

        step { operations.rename(c, to: "renamed.jpg") }
        let renamed = photos.appendingPathComponent("renamed.jpg")
        await until("rename") { self.exists(renamed) && !self.exists(c) }
        check("rename keeps the item in the model", window.model.media.contains { $0.url == renamed })
        undo.undo()
        await until("undo rename") { self.exists(c) && !self.exists(renamed) }

        step { operations.rotate([a], clockwise: true) }
        await until("rotate right sets EXIF orientation 6") { self.orientation(a) == 6 }
        check("rotation keeps the pixels untouched (same size)", pixelSize(a) == CGSize(width: 64, height: 48))
        undo.undo()
        await until("undo rotate restores orientation 1") { self.orientation(a) == 1 }

        await until("model has settled") { self.window.model.item(for: a) != nil }
        let red = FinderTags.all.first?.name ?? "Red"
        step { operations.toggleTag(red, on: [a]) }
        check("tag is written", tags(a).contains(red))
        undo.undo()
        check("undo tag removes it", !tags(a).contains(red))

        window.model.searchText = "b"
        check("search filters by name", window.model.media.map(\.name) == ["b.jpg"])
        window.model.searchText = ""
        check("clearing search shows all", window.model.media.count == 3)
    }

    // MARK: - Helpers

    private func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        print((passed ? "PASS  " : "FAIL  ") + name)
    }

    private func until(_ name: String, timeout: Double = 4, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        check(name, condition())
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func orientation(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return -1 }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    private func pixelSize(_ url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .zero }
        return CGSize(width: width, height: height)
    }

    private func tags(_ url: URL) -> [String] {
        // A fresh URL: resource values are cached per URL object.
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    private func writeImage(_ url: URL) throws {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
