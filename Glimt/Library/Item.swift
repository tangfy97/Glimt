import Foundation

/// One entry in a folder: a subfolder, an image or a video.
struct Item: Hashable, Sendable {
    enum Kind: Sendable {
        case folder, image, video
    }

    let url: URL
    let kind: Kind
    /// Uniform type identifier, for sorting by kind.
    let type: String
    let fileSize: Int
    let modified: Date
    let created: Date
    let added: Date
    var tags: [String]

    var name: String { url.lastPathComponent }
    var isMedia: Bool { kind != .folder }

    func renamed(to url: URL) -> Item {
        Item(url: url, kind: kind, type: type, fileSize: fileSize, modified: modified, created: created, added: added, tags: tags)
    }
}
