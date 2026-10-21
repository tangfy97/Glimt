import AppKit

// Pure AppKit entry point: no storyboard, no SwiftUI scene graph to stand up at launch.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
