import AppKit
import ImageIO

/// Every change Glimt makes to files: sort into folders, copy, trash, rename, rotate, tag.
/// The model is updated first so the UI moves on instantly; the file work runs in the
/// background. Each operation registers its inverse with the window's undo manager
/// synchronously, so undo and redo nest correctly even while work is still in flight.
@MainActor
final class FileOperations {
    struct Move: Sendable {
        let from: URL
        let to: URL
    }

    let undoManager = UndoManager()
    weak var model: FolderModel?
    /// Called with a user-facing message when something could not be done.
    var onError: ((String) -> Void)?
    /// Called when a file's pixels changed (rotation) so caches can drop it.
    var onContentsChanged: ((URL) -> Void)?

    // MARK: - Companions

    /// Sidecar extensions that travel with their image even though they aren't listed.
    private static let sidecarExtensions = ["xmp", "XMP", "aae", "AAE"]

    /// `urls` plus, when enabled, their RAW+JPEG partners, Live Photo movies and sidecars, so a
    /// shot is never split up by sorting or trashing.
    func withCompanions(_ urls: [URL]) -> [URL] {
        guard Preferences.movesCompanions, let model else { return urls }
        var result: [URL] = []
        var seen: Set<String> = []
        func add(_ url: URL) {
            if seen.insert(url.path).inserted { result.append(url) }
        }
        for url in urls {
            add(url)
            for sibling in model.siblings(of: url) { add(sibling) }
            let base = url.deletingPathExtension()
            for ext in Self.sidecarExtensions {
                let sidecar = base.appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: sidecar.path) { add(sidecar) }
            }
        }
        return result
    }

    // MARK: - Move, copy, trash

    func move(_ urls: [URL], into folder: URL) {
        let moves = Self.destinations(for: withCompanions(urls), in: folder)
        guard !moves.isEmpty else { return }
        relocate(moves, actionName: String(localized: "Move"))
    }

    func copy(_ urls: [URL], into folder: URL) {
        let copies = Self.destinations(for: withCompanions(urls), in: folder)
        guard !copies.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated { operations.trash(copies.map(\.to), includingCompanions: false) }
        }
        undoManager.setActionName(String(localized: "Copy"))
        Task {
            let failures = await Self.inBackground {
                copies.compactMap { copy -> String? in
                    do { try FileManager.default.copyItem(at: copy.from, to: copy.to); return nil }
                    catch { return error.localizedDescription }
                }
            }
            report(failures)
            model?.scheduleRefresh()
        }
    }

    func trash(_ urls: [URL], includingCompanions: Bool = true) {
        let urls = includingCompanions ? withCompanions(urls) : urls
        guard !urls.isEmpty else { return }
        model?.remove(Set(urls))
        // Where each file lands in the Trash is only known afterwards; undo reads it then.
        let record = MoveRecord()
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated {
                operations.relocate(record.moves.map { Move(from: $0.to, to: $0.from) }, actionName: String(localized: "Move to Trash"))
            }
        }
        undoManager.setActionName(String(localized: "Move to Trash"))
        Task {
            let result = await Self.inBackground {
                var moves: [Move] = []
                var failures: [String] = []
                for url in urls {
                    var trashed: NSURL?
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                        if let trashed = trashed as URL? { moves.append(Move(from: url, to: trashed)) }
                    } catch {
                        failures.append(error.localizedDescription)
                    }
                }
                return (moves, failures)
            }
            record.moves = result.0
            report(result.1)
            model?.scheduleRefresh()
        }
    }

    /// Moves files, keeping the model in step: listed files moved elsewhere disappear at once,
    /// files renamed in place keep their position, files arriving show up on the next rescan.
    private func relocate(_ moves: [Move], actionName: String) {
        guard !moves.isEmpty else { return }
        var leaving: Set<URL> = []
        for move in moves where model?.contains(move.from) == true {
            let samePlace = move.from.deletingLastPathComponent().standardizedFileURL.path
                == move.to.deletingLastPathComponent().standardizedFileURL.path
            if samePlace {
                model?.rename(from: move.from, to: move.to)
            } else {
                leaving.insert(move.from)
            }
        }
        model?.remove(leaving)

        let inverse = moves.map { Move(from: $0.to, to: $0.from) }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated { operations.relocate(inverse, actionName: actionName) }
        }
        undoManager.setActionName(actionName)

        Task {
            let failures = await Self.inBackground {
                moves.compactMap { move -> String? in
                    do {
                        try FileManager.default.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: move.from, to: move.to)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            report(failures)
            model?.scheduleRefresh()
        }
    }

    // MARK: - Rename

    func rename(_ url: URL, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        guard !name.contains("/"), !name.hasPrefix(".") else {
            onError?(String(localized: "“\(name)” can’t be used as a file name."))
            return
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            onError?(String(localized: "There is already a file named “\(name)”."))
            return
        }
        // Partners keep matching: IMG_1.JPG → Beach.JPG also renames IMG_1.CR3 → Beach.CR3.
        let newBase = (name as NSString).deletingPathExtension
        var moves = [Move(from: url, to: destination)]
        for companion in withCompanions([url]).dropFirst() {
            let target = companion.deletingLastPathComponent().appendingPathComponent(newBase).appendingPathExtension(companion.pathExtension)
            if !FileManager.default.fileExists(atPath: target.path) { moves.append(Move(from: companion, to: target)) }
        }
        relocate(moves, actionName: String(localized: "Rename"))
    }

    // MARK: - Rotate and flip

    /// Lossless: only the EXIF orientation changes, the pixels are not re-encoded.
    func transform(_ urls: [URL], _ transform: ImageRotator.Transform) {
        guard !urls.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated { operations.transform(urls, transform.inverse) }
        }
        undoManager.setActionName(transform.actionName)
        Task {
            let failures = await Self.inBackground {
                urls.compactMap { url -> String? in
                    do { try ImageRotator.apply(transform, to: url); return nil }
                    catch { return String(localized: "“\(url.lastPathComponent)” can’t be turned without re-encoding it.") }
                }
            }
            for url in urls { onContentsChanged?(url) }
            report(failures)
            model?.scheduleRefresh()
        }
    }

    // MARK: - Tags

    func toggleTag(_ tag: String, on urls: [URL]) {
        let items = urls.compactMap { model?.item(for: $0) }
        guard !items.isEmpty else { return }
        // If every file already has it, remove it; otherwise add it to all.
        let adding = !items.allSatisfy { $0.tags.contains(tag) }
        var changes: [(URL, [String])] = []
        for item in items {
            var tags = item.tags.filter { $0 != tag }
            if adding { tags.append(tag) }
            changes.append((item.url, tags))
        }
        applyTags(changes, actionName: adding ? String(localized: "Add Tag") : String(localized: "Remove Tag"))
    }

    func clearTags(on urls: [URL]) {
        let changes = urls.compactMap { url in model?.item(for: url).map { ($0.url, [String]()) } }
        applyTags(changes, actionName: String(localized: "Clear Tags"))
    }

    private func applyTags(_ changes: [(URL, [String])], actionName: String) {
        var previous: [(URL, [String])] = []
        for (url, tags) in changes {
            previous.append((url, model?.item(for: url)?.tags ?? []))
            do {
                try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
                model?.setTags(tags, for: url)
            } catch {
                onError?(error.localizedDescription)
            }
        }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated { operations.applyTags(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Helpers

    private func report(_ failures: [String]) {
        guard let first = failures.first else { return }
        onError?(failures.count == 1 ? first : String(localized: "\(failures.count) files couldn’t be changed. \(first)"))
    }

    /// Destination URLs in `folder`, numbering names that already exist ("IMG 2.jpg").
    private static func destinations(for urls: [URL], in folder: URL) -> [Move] {
        var taken: Set<String> = []
        return urls.compactMap { url in
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path != folder.resolvingSymlinksInPath().path else { return nil }
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var candidate = url.lastPathComponent
            var number = 2
            while taken.contains(candidate) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
                number += 1
            }
            taken.insert(candidate)
            return Move(from: url, to: folder.appendingPathComponent(candidate))
        }
    }

    /// All file work runs here, one operation at a time, in the order it was issued, so an
    /// undo that follows a rotate (or a move) never races the work it is undoing.
    nonisolated private static let queue = DispatchQueue(label: "Glimt.fileOperations", qos: .userInitiated)

    nonisolated private static func inBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

@MainActor
private final class MoveRecord {
    var moves: [FileOperations.Move] = []
}

enum ImageRotator {
    enum Failure: Error { case unreadable, unsupported }

    enum Transform: Sendable {
        case rotateRight, rotateLeft, rotate180, flipHorizontal, flipVertical

        var inverse: Transform {
            switch self {
            case .rotateRight: .rotateLeft
            case .rotateLeft: .rotateRight
            default: self
            }
        }

        var actionName: String {
            switch self {
            case .rotateRight: String(localized: "Rotate Right")
            case .rotateLeft: String(localized: "Rotate Left")
            case .rotate180: String(localized: "Rotate 180°")
            case .flipHorizontal: String(localized: "Flip Horizontal")
            case .flipVertical: String(localized: "Flip Vertical")
            }
        }

        /// The transform as a matrix in image coordinates (y pointing down).
        fileprivate var matrix: Matrix {
            switch self {
            case .rotateRight: Matrix(0, -1, 1, 0)
            case .rotateLeft: Matrix(0, 1, -1, 0)
            case .rotate180: Matrix(-1, 0, 0, -1)
            case .flipHorizontal: Matrix(-1, 0, 0, 1)
            case .flipVertical: Matrix(1, 0, 0, -1)
            }
        }
    }

    fileprivate struct Matrix: Equatable {
        let a, b, c, d: Int
        init(_ a: Int, _ b: Int, _ c: Int, _ d: Int) { (self.a, self.b, self.c, self.d) = (a, b, c, d) }
        static func * (l: Matrix, r: Matrix) -> Matrix {
            Matrix(l.a * r.a + l.b * r.c, l.a * r.b + l.b * r.d, l.c * r.a + l.d * r.c, l.c * r.b + l.d * r.d)
        }
    }

    /// What each EXIF orientation does to the stored pixels to display them.
    private static let orientations: [Int: Matrix] = [
        1: Matrix(1, 0, 0, 1), 2: Matrix(-1, 0, 0, 1), 3: Matrix(-1, 0, 0, -1), 4: Matrix(1, 0, 0, -1),
        5: Matrix(0, 1, 1, 0), 6: Matrix(0, -1, 1, 0), 7: Matrix(0, -1, -1, 0), 8: Matrix(0, 1, -1, 0),
    ]

    static func orientation(after transform: Transform, from current: Int) -> Int? {
        guard let matrix = orientations[current] else { return nil }
        let result = transform.matrix * matrix
        return orientations.first { $0.value == result }?.key
    }

    static func apply(_ transform: Transform, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw Failure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let current = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard let next = orientation(after: transform, from: current) else { throw Failure.unsupported }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).glimt")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else { throw Failure.unsupported }
        let options = [kCGImageDestinationOrientation: next] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.unsupported
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
