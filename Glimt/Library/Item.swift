import Foundation

/// One entry in a folder: a subfolder, an image or a video.
struct Item: Hashable, Sendable {
    enum Kind: Sendable {
        case folder, image, video
    }

    let url: URL
    let kind: Kind
    let fileSize: Int
    let modified: Date
    let created: Date
    var tags: [String]

    var name: String { url.lastPathComponent }
    var isMedia: Bool { kind != .folder }
}
