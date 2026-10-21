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

        // ImageIO's RAW plugin registers defaults on a decode thread; that must not crash the window.
        await Task.detached { UserDefaults.standard.register(defaults: ["GlimtSelfTestBackgroundDefault": true]) }.value
        await until("a default registered off the main thread is handled") { UserDefaults.standard.bool(forKey: "GlimtSelfTestBackgroundDefault") }

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

        step { operations.transform([a], .rotateRight) }
        await until("rotate right sets EXIF orientation 6") { self.orientation(a) == 6 }
        check("rotation keeps the pixels untouched (same size)", pixelSize(a) == CGSize(width: 64, height: 48))
        undo.undo()
        await until("undo rotate restores orientation 1") { self.orientation(a) == 1 }
        step { operations.transform([a], .flipHorizontal) }
        await until("flip horizontal sets orientation 2") { self.orientation(a) == 2 }
        step { operations.transform([a], .rotateRight) }
        await until("then rotate right gives orientation 7") { self.orientation(a) == 7 }
        undo.undo()
        undo.undo()
        await until("undo both restores orientation 1") { self.orientation(a) == 1 }
        check("orientation math: 180° from 6 is 8", ImageRotator.orientation(after: .rotate180, from: 6) == 8)
        check("orientation math: flip vertical from 1 is 4", ImageRotator.orientation(after: .flipVertical, from: 1) == 4)

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

        // RAW+JPEG pairs and sidecars travel together.
        let pairJPEG = photos.appendingPathComponent("pair.jpg")
        let pairPNG = photos.appendingPathComponent("pair.png")
        let sidecar = photos.appendingPathComponent("pair.xmp")
        try? writeImage(pairJPEG)
        try? writeImage(pairPNG)
        try? Data("<x:xmpmeta/>".utf8).write(to: sidecar)
        window.model.scheduleRefresh()
        await until("pair appears in the model") { self.window.model.item(for: pairPNG) != nil }
        step { operations.move([pairJPEG], into: keep) }
        await until("moving one file of a pair moves its partner and sidecar") {
            self.exists(self.keep.appendingPathComponent("pair.jpg")) && self.exists(self.keep.appendingPathComponent("pair.png"))
                && self.exists(self.keep.appendingPathComponent("pair.xmp")) && !self.exists(pairPNG)
        }
        undo.undo()
        await until("undo brings the whole pair back") { self.exists(pairJPEG) && self.exists(pairPNG) && self.exists(sidecar) }

        // Subfolders.
        let nested = photos.appendingPathComponent("nested/deeper")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try? writeImage(nested.appendingPathComponent("deep.jpg"))
        window.model.includesSubfolders = true
        await until("include subfolders finds nested images") { self.window.model.media.contains { $0.name == "deep.jpg" } }
        check("include subfolders hides folder tiles", window.model.folders.isEmpty)
        window.model.includesSubfolders = false
        await until("turning it off goes back to this folder only") { !self.window.model.media.contains { $0.name == "deep.jpg" } && !self.window.model.folders.isEmpty }

        // Folder columns follow whatever folder is open, and the grid drops its folder tiles.
        await until("folder columns show the open folder") { self.samePath(self.window.folderColumns.selectedURL, self.photos) }
        check("grid hides folder tiles while columns show", !window.browser.showsFolderTiles || !Preferences.showsFolderColumns)
        window.open(photos.appendingPathComponent("nested"))
        await until("opening a subfolder moves the columns") { self.samePath(self.window.folderColumns.selectedURL, self.photos.appendingPathComponent("nested")) }
        window.openEnclosingFolder(nil)
        await until("enclosing folder moves them back") { self.samePath(self.window.folderColumns.selectedURL, self.photos) }
        window.folderColumns.onOpen?(photos.appendingPathComponent("nested"))
        await until("picking a folder in the columns opens it in the grid") { self.samePath(self.window.model.folder, self.photos.appendingPathComponent("nested")) }
        // Keyboard: ← goes to the parent folder, → into its first subfolder.
        await until("columns reach the subfolder before keys") { self.samePath(self.window.folderColumns.selectedURL, self.photos.appendingPathComponent("nested")) }
        if let table = window.folderColumns.currentTable {
            window.window?.makeFirstResponder(table)
            table.keyDown(with: key(NSLeftArrowFunctionKey))
            await until("← in the columns opens the parent folder") { self.samePath(self.window.model.folder, self.photos) }
            window.folderColumns.currentTable?.keyDown(with: key(NSRightArrowFunctionKey))
            await until("→ opens its first subfolder") { self.samePath(self.window.model.folder, self.photos.appendingPathComponent("nested")) }
        } else {
            check("columns have a current table", false)
        }

        window.goBack(nil)
        await until("Back returns to the previous folder") { self.samePath(self.window.model.folder, self.photos) }
        window.goForward(nil)
        await until("Forward goes to the subfolder again") { self.samePath(self.window.model.folder, self.photos.appendingPathComponent("nested")) }
        window.open(photos)
        await until("back in photos") { self.samePath(self.window.model.folder, self.photos) && self.window.model.media.count >= 3 }

        window.model.sortKey = .kind
        check("sort by kind puts JPEG before PNG", window.model.media.map(\.name).firstIndex(of: "a.jpg")! < window.model.media.map(\.name).firstIndex(of: "pair.png")!)
        window.model.sortKey = .name
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

    private func key(_ functionKey: Int) -> NSEvent {
        let character = String(Character(UnicodeScalar(UInt16(functionKey))!))
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                windowNumber: window.window?.windowNumber ?? 0, context: nil, characters: character,
                                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }

    private func samePath(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
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
