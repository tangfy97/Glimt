import AppKit

/// Identity and links. The bundle identifier comes from the build settings (project.yml),
/// so a fork changes it in one place.
enum AppInfo {
    static let identifier = Bundle.main.bundleIdentifier ?? "Glimt"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    enum Link {
        static let repository = URL(string: "https://github.com/tangfy97/Glimt")!
        static let issues = URL(string: "https://github.com/tangfy97/Glimt/issues/new/choose")!
        /// `ref` lets the studio see visits that came from the app.
        static let studio = URL(string: "https://tang-spark.no/?ref=glimt")!
    }

    /// Credits under the version in the About panel.
    @MainActor static var aboutCredits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]
        func link(_ title: String, _ url: URL) -> NSAttributedString {
            var attributes = body
            attributes[.link] = url
            return NSAttributedString(string: title, attributes: attributes)
        }
        let credits = NSMutableAttributedString(string: String(localized: "Made in Norway by TangSpark.") + "\n", attributes: body)
        credits.append(link("tang-spark.no", Link.studio))
        credits.append(NSAttributedString(string: "  ·  ", attributes: body))
        credits.append(link(String(localized: "Source code"), Link.repository))
        return credits
    }
}
