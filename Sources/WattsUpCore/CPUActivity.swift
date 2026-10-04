import Foundation

public enum CPUActivity {
    /// Per-CPU tick layout of PROCESSOR_CPU_LOAD_INFO: user, system, idle, nice.
    public static let statesPerCPU = 4

    /// Fraction of all-core time spent busy (user + system + nice) between two
    /// tick snapshots. The kernel counters are 32-bit and wrap, hence `&-`.
    /// Returns nil when the snapshots do not line up or no time has passed.
    public static func busyFraction(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == current.count, !current.isEmpty, current.count % statesPerCPU == 0 else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for base in stride(from: 0, to: current.count, by: statesPerCPU) {
            let user = UInt64(current[base] &- previous[base])
            let system = UInt64(current[base + 1] &- previous[base + 1])
            let idle = UInt64(current[base + 2] &- previous[base + 2])
            let nice = UInt64(current[base + 3] &- previous[base + 3])
            busy += user + system + nice
            total += user + system + idle + nice
        }
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }
}
