import AVFoundation
import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct InspectorSection: Identifiable, Sendable {
    struct Row: Identifiable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    let title: String
    let rows: [Row]
    var id: String { title }
}

@MainActor
@Observable
final class InspectorModel {
    var title = ""
    var sections: [InspectorSection] = []
    private var generation = 0

    func load(_ item: Item?) {
        generation += 1
        let current = generation
        guard let item else {
            title = String(localized: "No Selection")
            sections = []
            return
        }
        title = item.name
        Task {
            let sections = await MetadataReader.sections(for: item)
            guard current == self.generation else { return }
            self.sections = sections
        }
    }
}

/// Floating Info panel (⌘I): file facts, camera and exposure, location.
@MainActor
final class InspectorController: NSObject {
    private var panel: NSPanel?
    private let model = InspectorModel()
    private var pending: Item?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(beside window: NSWindow?) {
        if isVisible {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel(beside: window)
        self.panel = panel
        model.load(pending)
        panel.orderFront(nil)
    }

    func update(_ item: Item?) {
        guard pending?.url != item?.url || pending?.tags != item?.tags else { return }
        pending = item
        if isVisible { model.load(item) }
    }

    func refresh() {
        if isVisible { model.load(pending) }
    }

    private func makePanel(beside window: NSWindow?) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 480),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = String(localized: "Info")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: InspectorView(model: model))
        panel.setFrameAutosaveName("Inspector")
        if !panel.setFrameUsingName("Inspector"), let window {
            panel.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX + 8, y: window.frame.maxY))
        }
        return panel
    }
}

struct InspectorView: View {
    let model: InspectorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                            ForEach(section.rows) { row in
                                GridRow {
                                    Text(row.label)
                                        .foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                    Text(row.value)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(minWidth: 260, minHeight: 240)
    }
}

enum MetadataReader {
    typealias Row = InspectorSection.Row

    static func sections(for item: Item) async -> [InspectorSection] {
        var sections = [fileSection(item)]
        switch item.kind {
        case .image:
            sections += await Task.detached(priority: .userInitiated) { imageSections(item.url) }.value
        case .video:
            sections += await videoSections(item.url)
        case .folder:
            break
        }
        return sections.filter { !$0.rows.isEmpty }
    }

    private static func fileSection(_ item: Item) -> InspectorSection {
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        var rows: [Row] = []
        if let type = try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            rows.append(Row(label: String(localized: "Kind"), value: type.localizedDescription ?? type.identifier))
        }
        if item.kind != .folder {
            rows.append(Row(label: String(localized: "Size"), value: ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)))
        }
        rows.append(Row(label: String(localized: "Modified"), value: date.string(from: item.modified)))
        rows.append(Row(label: String(localized: "Created"), value: date.string(from: item.created)))
        if !item.tags.isEmpty {
            rows.append(Row(label: String(localized: "Tags"), value: item.tags.joined(separator: ", ")))
        }
        rows.append(Row(label: String(localized: "Where"), value: (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        return InspectorSection(title: String(localized: "File"), rows: rows)
    }

    private static func imageSections(_ url: URL) -> [InspectorSection] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var image: [Row] = []
        if let size = ImageDecoder.orientedSize(of: source) {
            let megapixels = size.width * size.height / 1_000_000
            image.append(Row(label: String(localized: "Dimensions"), value: String(format: "%d × %d  (%.1f MP)", Int(size.width), Int(size.height), megapixels)))
        }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { image.append(Row(label: String(localized: "Frames"), value: "\(frames)")) }
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            image.append(Row(label: String(localized: "Color Profile"), value: profile))
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            image.append(Row(label: String(localized: "Bit Depth"), value: "\(depth)"))
        }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            image.append(Row(label: String(localized: "Taken"), value: taken))
        }

        var camera: [Row] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            let name = make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model
            camera.append(Row(label: String(localized: "Camera"), value: name))
        }
        if let lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String) {
            camera.append(Row(label: String(localized: "Lens"), value: lens))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            var value = String(format: "%g mm", focal)
            if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, equivalent > 0, Double(equivalent) != focal {
                value += String(localized: " (\(equivalent) mm equiv.)")
            }
            camera.append(Row(label: String(localized: "Focal Length"), value: value))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
            camera.append(Row(label: String(localized: "Aperture"), value: String(format: "ƒ/%g", aperture)))
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            let value = exposure >= 1 ? String(format: "%g s", exposure) : "1/\(Int((1 / exposure).rounded())) s"
            camera.append(Row(label: String(localized: "Shutter"), value: value))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            camera.append(Row(label: "ISO", value: "\(iso)"))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            camera.append(Row(label: String(localized: "Exposure"), value: String(format: "%+.1f EV", bias)))
        }

        var location: [Row] = []
        if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let ew = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            location.append(Row(label: String(localized: "Coordinates"), value: String(format: "%.5f° %@, %.5f° %@", latitude, ns, longitude, ew)))
            if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
                location.append(Row(label: String(localized: "Altitude"), value: String(format: "%.0f m", altitude)))
            }
        }

        return [
            InspectorSection(title: String(localized: "Image"), rows: image),
            InspectorSection(title: String(localized: "Camera"), rows: camera),
            InspectorSection(title: String(localized: "Location"), rows: location),
        ]
    }

    private static func videoSections(_ url: URL) async -> [InspectorSection] {
        let asset = AVURLAsset(url: url)
        var rows: [Row] = []
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
            let seconds = Int(duration.seconds.rounded())
            rows.append(Row(label: String(localized: "Duration"), value: String(format: "%d:%02d", seconds / 60, seconds % 60)))
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform, rate) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) {
            let oriented = size.applying(transform)
            rows.append(Row(label: String(localized: "Dimensions"), value: "\(Int(abs(oriented.width))) × \(Int(abs(oriented.height)))"))
            if rate > 0 { rows.append(Row(label: String(localized: "Frame Rate"), value: String(format: "%.3g fps", rate))) }
        }
        return [InspectorSection(title: String(localized: "Video"), rows: rows)]
    }
}
