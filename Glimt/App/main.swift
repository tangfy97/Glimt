import AppKit

// Pure AppKit entry point: no storyboard, no SwiftUI scene graph to stand up at launch.
if ProcessInfo.processInfo.environment["GLIMT_BENCH"] != nil {
    print(String(format: "process start → main: %.1f ms", ProcessMetrics.millisecondsSinceProcessStart()))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
