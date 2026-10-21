import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FolderScanner {
    /// Upper bound for a recursive scan, so pointing it at a home folder stays usable.
    static let recursiveLimit = 100_000

    /// Subfolders, images and videos directly inside `folder`, or with `recursive` every image
    /// and video below it (and no folders). Runs off the main thread.
    static func items(in folder: URL, recursive: Bool) async -> [Item] {
        await Task.detached(priority: .userInitiated) {
            recursive ? scanRecursively(folder) : scan(folder)
        }.value
    }

    /// Finder tags live in extended attributes and cost ~3x everything else together, so
    /// they are read in a second pass (`tags(for:)`) after the grid is already up.
    private static let keys: Set<URLResourceKey> = [
        .contentTypeKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey,
    ]

    /// Tags for the files that have any.
    static func tags(for urls: [URL]) async -> [URL: [String]] {
        await Task.detached(priority: .utility) {
            var result: [URL: [String]] = [:]
            for url in urls {
                if let tags = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames, !tags.isEmpty {
                    result[url] = tags
                }
            }
            return result
        }.value
    }

    private static let imageTypes: [UTType] = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
    }()

    private static let videoTypes: [UTType] = {
        AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }.filter { $0.conforms(to: .movie) }
    }()

    private static func scan(_ folder: URL) -> [Item] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var classifier = Classifier()
        return contents.compactMap { url in
            // Built from `folder` (not the enumerated URL, which may say /private/var for /var)
            // so every item URL has the same form as the folder the model resolved.
            classifier.item(at: url, as: folder.appendingPathComponent(url.lastPathComponent), foldersAllowed: true)
        }
    }

    private static func scanRecursively(_ folder: URL) -> [Item] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        // The enumerator reports real paths (/private/var/...); map them back onto `folder`.
        let realRoot = realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? folder.path
        var classifier = Classifier()
        var items: [Item] = []
        while let url = enumerator.nextObject() as? URL {
            let path = url.path
            let relative: Substring
            if path.hasPrefix(realRoot + "/") {
                relative = path.dropFirst(realRoot.count + 1)
            } else if path.hasPrefix(folder.path + "/") {
                relative = path.dropFirst(folder.path.count + 1)
            } else {
                continue
            }
            if let item = classifier.item(at: url, as: folder.appendingPathComponent(String(relative)), foldersAllowed: false) {
                items.append(item)
                if items.count >= recursiveLimit { break }
            }
        }
        return items
    }

    private struct Classifier {
        private var verdicts: [String: Item.Kind?] = [:]

        mutating func item(at url: URL, as itemURL: URL, foldersAllowed: Bool) -> Item? {
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let kind: Item.Kind?
            if values.isDirectory == true {
                kind = values.isPackage == true || !foldersAllowed ? nil : .folder
            } else if values.isRegularFile == true, let type = values.contentType {
                if let cached = verdicts[type.identifier] {
                    kind = cached
                } else {
                    kind = FolderScanner.classify(type)
                    verdicts[type.identifier] = kind
                }
            } else {
                kind = nil
            }
            guard let kind else { return nil }
            return Item(
                url: itemURL, kind: kind, type: values.contentType?.identifier ?? "",
                fileSize: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast,
                created: values.creationDate ?? .distantPast,
                added: values.addedToDirectoryDate ?? values.creationDate ?? .distantPast,
                tags: [])
        }
    }

    private static func classify(_ type: UTType) -> Item.Kind? {
        if type.conforms(to: .image), imageTypes.contains(where: { type.conforms(to: $0) }) { return .image }
        if type.conforms(to: .movie), videoTypes.contains(where: { type.conforms(to: $0) }) { return .video }
        return nil
    }
}
