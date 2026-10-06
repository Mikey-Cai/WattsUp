import Foundation

/// One "how busy is it" reading for the usage card. Every field is optional:
/// nil means unknown (no source on this Mac, or no baseline yet), never 0.
public struct UsageReading: Codable, Sendable, Equatable {
    /// One kind of CPU core, highest-performance kind first.
    public struct CoreGroup: Codable, Sendable, Equatable {
        /// The kernel's name for this performance level ("Performance", "Efficiency", …).
        public let name: String
        public let cpuCount: Int
        /// 0…1; nil until a second tick snapshot exists.
        public let busy: Double?

        public init(name: String, cpuCount: Int, busy: Double?) {
            self.name = name
            self.cpuCount = cpuCount
            self.busy = busy
        }
    }

    /// All-core busy fraction, 0…1.
    public var cpuBusy: Double?
    /// nil when the cores of this Mac cannot be told apart reliably.
    public var coreGroups: [CoreGroup]?
    /// IOAccelerator "Device Utilization %", as 0…1.
    public var gpuBusy: Double?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var networkReceivedBytesPerSecond: Double?
    public var networkSentBytesPerSecond: Double?
    /// Metrics that have a source but are still waiting for their first
    /// baseline ("cpu", "disk", "network"). Anything nil and not listed here
    /// is unavailable and is not shown.
    public var pending: [String]

    public init(cpuBusy: Double? = nil, coreGroups: [CoreGroup]? = nil, gpuBusy: Double? = nil,
                diskReadBytesPerSecond: Double? = nil, diskWriteBytesPerSecond: Double? = nil,
                networkReceivedBytesPerSecond: Double? = nil, networkSentBytesPerSecond: Double? = nil,
                pending: [String] = []) {
        self.cpuBusy = cpuBusy
        self.coreGroups = coreGroups
        self.gpuBusy = gpuBusy
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceivedBytesPerSecond = networkReceivedBytesPerSecond
        self.networkSentBytesPerSecond = networkSentBytesPerSecond
        self.pending = pending
    }

    public func isPending(_ metric: String) -> Bool { pending.contains(metric) }

    /// Nothing to show at all: no reading and nothing on its way.
    public var isEmpty: Bool {
        cpuBusy == nil && gpuBusy == nil && diskReadBytesPerSecond == nil && diskWriteBytesPerSecond == nil
            && networkReceivedBytesPerSecond == nil && networkSentBytesPerSecond == nil && pending.isEmpty
    }
}

public enum UsageRates {
    /// Per-second rate of a monotonically increasing byte counter. A counter
    /// that went backwards (device removed, driver reset) gives nil rather
    /// than a huge or negative rate.
    public static func perSecond(previous: UInt64, current: UInt64, seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0, current >= previous else { return nil }
        return Double(current - previous) / seconds
    }

    /// Combined per-second rate over several counters keyed by device (block
    /// driver or network interface). Only devices present in both snapshots
    /// count, and a device whose counter went backwards is skipped, so
    /// plugging in or ejecting a disk never produces a spike. nil when no
    /// device is in both snapshots.
    public static func summedPerSecond(previous: [UInt64: UInt64], current: [UInt64: UInt64], seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        var total: UInt64 = 0
        var matched = false
        for (key, now) in current {
            guard let before = previous[key] else { continue }
            matched = true
            if now >= before { total += now - before }
        }
        return matched ? Double(total) / seconds : nil
    }

    /// IOAccelerator reports a whole-number percentage; anything outside 0…100 is not trusted.
    public static func gpuFraction(percent: Double?) -> Double? {
        guard let percent, percent.isFinite, percent >= 0, percent <= 100 else { return nil }
        return percent / 100
    }
}

extension CPUActivity {
    /// Busy fraction over only the CPUs in `cpus` (indices into the per-CPU
    /// tick arrays). nil when none of them are present or no time has passed.
    public static func busyFraction(previous: [UInt32], current: [UInt32], cpus: Set<Int>) -> Double? {
        guard previous.count == current.count, current.count % statesPerCPU == 0, !cpus.isEmpty else { return nil }
        let cpuCount = current.count / statesPerCPU
        guard cpus.allSatisfy({ (0..<cpuCount).contains($0) }) else { return nil }
        var before: [UInt32] = []
        var after: [UInt32] = []
        for cpu in cpus.sorted() {
            let base = cpu * statesPerCPU
            before += previous[base..<base + statesPerCPU]
            after += current[base..<base + statesPerCPU]
        }
        return busyFraction(previous: before, current: after)
    }
}

/// Which CPU belongs to which kind of core.
public enum CPUClusters {
    /// - Parameters:
    ///   - clusterTypeByCPU: logical CPU id → the device tree's "cluster-type"
    ///     letter ("E", "P", "M", …).
    ///   - perfLevelCounts: logical CPU count of hw.perflevel0, 1, 2, … (the
    ///     kernel lists the highest-performance level first).
    /// - Returns: logical CPU id → perflevel index, or nil when the two
    ///   sources cannot be matched without guessing.
    ///
    /// Letters are matched to levels by core count when every count is
    /// different. The only other case accepted is the classic two-level chip
    /// with exactly "P" and "E" letters. Anything else (two levels with the
    /// same count, CPUs missing from the device tree) is left unsplit.
    public static func assign(clusterTypeByCPU: [Int: String], perfLevelCounts: [Int]) -> [Int: Int]? {
        guard !perfLevelCounts.isEmpty, perfLevelCounts.allSatisfy({ $0 > 0 }),
              clusterTypeByCPU.count == perfLevelCounts.reduce(0, +) else { return nil }
        var cpusByLetter: [String: [Int]] = [:]
        for (cpu, letter) in clusterTypeByCPU { cpusByLetter[letter, default: []].append(cpu) }
        guard cpusByLetter.count == perfLevelCounts.count else { return nil }

        var levelByLetter: [String: Int] = [:]
        if Set(perfLevelCounts).count == perfLevelCounts.count {
            for (letter, cpus) in cpusByLetter {
                guard let level = perfLevelCounts.firstIndex(of: cpus.count) else { return nil }
                levelByLetter[letter] = level
            }
        } else if perfLevelCounts.count == 2, Set(cpusByLetter.keys) == ["P", "E"],
                  cpusByLetter["P"]?.count == perfLevelCounts[0], cpusByLetter["E"]?.count == perfLevelCounts[1] {
            levelByLetter = ["P": 0, "E": 1]
        } else {
            return nil
        }
        guard Set(levelByLetter.values).count == perfLevelCounts.count else { return nil }
        var result: [Int: Int] = [:]
        for (cpu, letter) in clusterTypeByCPU { result[cpu] = levelByLetter[letter] }
        return result
    }

    /// Chinese label for the kernel's perflevel name; unknown names are shown as is.
    public static func title(forLevelName name: String) -> String {
        switch name {
        case "Super": return "超级核"
        case "Performance": return "性能核"
        case "Efficiency": return "能效核"
        default: return name
        }
    }
}
