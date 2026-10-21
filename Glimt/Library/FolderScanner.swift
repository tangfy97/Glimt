import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FolderScanner {
    /// Image files directly inside `folder`, in Finder order. Runs off the main thread.
    static func imageURLs(in folder: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) { scan(folder) }.value
    }

    private static let decodableTypes: [UTType] = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
    }()

    private static func scan(_ folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var verdicts: [String: Bool] = [:]
        var named: [(name: String, url: URL)] = []
        named.reserveCapacity(contents.count)
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let type = values.contentType else { continue }
            let decodable = verdicts[type.identifier] ?? {
                let verdict = decodableTypes.contains { type.conforms(to: $0) }
                verdicts[type.identifier] = verdict
                return verdict
            }()
            if decodable { named.append((url.lastPathComponent, url)) }
        }
        named.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return named.map(\.url)
    }
}
