import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FolderScanner {
    /// Subfolders, images and videos directly inside `folder`. Runs off the main thread.
    static func items(in folder: URL) async -> [Item] {
        await Task.detached(priority: .userInitiated) { scan(folder) }.value
    }

    /// Finder tags live in extended attributes and cost ~3x everything else together, so
    /// they are read in a second pass (`tags(for:)`) after the grid is already up.
    private static let keys: Set<URLResourceKey> = [
        .contentTypeKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
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

        var verdicts: [String: Item.Kind?] = [:]
        var items: [Item] = []
        items.reserveCapacity(contents.count)
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let kind: Item.Kind?
            if values.isDirectory == true {
                kind = values.isPackage == true ? nil : .folder
            } else if values.isRegularFile == true, let type = values.contentType {
                if let cached = verdicts[type.identifier] {
                    kind = cached
                } else {
                    kind = classify(type)
                    verdicts[type.identifier] = kind
                }
            } else {
                kind = nil
            }
            guard let kind else { continue }
            // Built from `folder` (not the enumerated URL, which may say /private/var for /var)
            // so every item URL has the same form as the folder the model resolved.
            items.append(Item(
                url: folder.appendingPathComponent(url.lastPathComponent), kind: kind, fileSize: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast,
                created: values.creationDate ?? .distantPast,
                tags: []))
        }
        return items
    }

    private static func classify(_ type: UTType) -> Item.Kind? {
        if type.conforms(to: .image), imageTypes.contains(where: { type.conforms(to: $0) }) { return .image }
        if type.conforms(to: .movie), videoTypes.contains(where: { type.conforms(to: $0) }) { return .video }
        return nil
    }
}
