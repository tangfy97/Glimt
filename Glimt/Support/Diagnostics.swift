import Darwin
import os

/// Points of Interest in Instruments: "Decode" and "Page Turn" intervals.
enum Signposts {
    static let signposter = OSSignposter(subsystem: "com.feiyangtang.Glimt", category: .pointsOfInterest)
}

enum ProcessMetrics {
    /// Physical footprint, the number Activity Monitor shows as "Memory".
    static func footprintBytes() -> UInt64 {
        rusage()?.ri_phys_footprint ?? 0
    }

    static func millisecondsSinceProcessStart() -> Double {
        guard let start = rusage()?.ri_proc_start_abstime else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let elapsed = mach_absolute_time() - start
        return Double(elapsed) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    private static func rusage() -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage : nil
    }
}
