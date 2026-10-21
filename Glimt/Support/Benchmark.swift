import AppKit

/// Performance run, enabled with the environment variable `GLIMT_BENCH=<steps>`
/// (optionally `GLIMT_BENCH_INTERVAL_MS`, default 120). Pages forward through the opened
/// folder, returns to the first image and zooms to actual size, prints a summary to stdout
/// and quits. Latencies are measured to the end of the Core Animation commit, i.e. the
/// moment the frame is handed to the render server.
@MainActor
final class Benchmark {
    private let viewer: ViewerWindowController
    private let launchMs: Double
    private let steps: Int
    private let interval: Duration
    private let verbose = ProcessInfo.processInfo.environment["GLIMT_BENCH_VERBOSE"] != nil

    private var target: URL?
    private var turnStart: CFTimeInterval = 0
    private var firstRecorded = true
    private var turns = 0
    private var prefetched = 0
    private var firstPixels: [Double] = []
    private var sharp: [Double] = []
    private var firstImageMs: Double?
    private var fullStart: CFTimeInterval?
    private var fullMs: Double?

    init?(viewer: ViewerWindowController, launchMs: Double) {
        let environment = ProcessInfo.processInfo.environment
        guard let steps = environment["GLIMT_BENCH"].flatMap(Int.init), steps > 0 else { return nil }
        self.viewer = viewer
        self.launchMs = launchMs
        self.steps = steps
        self.interval = .milliseconds(environment["GLIMT_BENCH_INTERVAL_MS"].flatMap(Int.init) ?? 120)
    }

    private var activity: NSObjectProtocol?

    func start() {
        // A shell-launched, possibly occluded window would otherwise be App Napped after
        // ~30 s, which throttles timers and commits and skews the numbers.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Benchmark")
        NSApp.activate()
        print(String(format: "launch → window: %.1f ms", launchMs))
        viewer.onImageShown = { [weak self] url, level in self?.imageShown(url, level) }
        viewer.onItemsLoaded = { [weak self] count, scanMs in
            print(String(format: "scan: %d images in %.1f ms", count, scanMs))
            self?.run()
        }
    }

    private func imageShown(_ url: URL, _ level: DecodeLevel) {
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.committed(url, level) }
        }
    }

    private func committed(_ url: URL, _ level: DecodeLevel) {
        let now = CACurrentMediaTime()
        if firstImageMs == nil { firstImageMs = ProcessMetrics.millisecondsSinceProcessStart() }
        if let fullStart, level == .full {
            fullMs = (now - fullStart) * 1000
            self.fullStart = nil
        }
        guard url == target else { return }
        let elapsed = (now - turnStart) * 1000
        if !firstRecorded {
            firstPixels.append(elapsed)
            firstRecorded = true
            if verbose, elapsed > 8 { print(String(format: "  slow turn %d: %.1f ms (%@)", turns, elapsed, level.description)) }
        }
        if level >= .preview {
            sharp.append(elapsed)
            target = nil
        }
    }

    private func run() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0..<steps {
                guard viewer.index + 1 < viewer.items.count else { break }
                let next = viewer.items[viewer.index + 1]
                if viewer.isCached(next) { prefetched += 1 }
                turns += 1
                target = next
                firstRecorded = false
                turnStart = CACurrentMediaTime()
                viewer.navigate(.next)
                try? await Task.sleep(for: interval)
            }
            target = nil
            viewer.navigate(.first)
            try? await Task.sleep(for: .milliseconds(500))
            fullStart = CACurrentMediaTime()
            viewer.zoomToActualSize(nil)
            try? await Task.sleep(for: .seconds(2))
            report()
            NSApp.terminate(nil)
        }
    }

    private func report() {
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return .nan }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        func line(_ name: String, _ values: [Double]) {
            print(String(format: "%@: n=%d  p50 %.2f ms · p95 %.2f ms · max %.2f ms",
                         name, values.count, percentile(values, 0.5), percentile(values, 0.95), values.max() ?? .nan))
        }
        print("page turns: \(turns), already decoded at key press: \(prefetched)")
        line("key → first pixels committed", firstPixels)
        line("key → screen-sharp committed", sharp)
        if let firstImageMs { print(String(format: "launch → first image: %.1f ms", firstImageMs)) }
        print(fullMs.map { String(format: "actual size → full-res committed: %.1f ms", $0) } ?? "actual size → full-res: not reached")
        print(String(format: "footprint: %.1f MB", Double(ProcessMetrics.footprintBytes()) / 1_048_576))
    }
}
