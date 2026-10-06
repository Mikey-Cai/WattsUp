import Darwin
import Foundation
import IOKit
import WattsUpCore

/// CPU, GPU, disk and network activity for the usage card. Everything here
/// works as an ordinary user without a helper. Rates and CPU busy need two
/// snapshots, so the first call reports them as pending.
/// Single owner: call from one queue.
public final class UsageSampler {
    private let host = mach_host_self()
    /// Logical CPU → perflevel index, nil when the cores cannot be told apart.
    private let levelByCPU: [Int: Int]?
    private let levels: [(name: String, cpuCount: Int)]
    private var previousTicks: [UInt32]?
    private var previousDisk: (time: TimeInterval, read: [UInt64: UInt64], write: [UInt64: UInt64])?
    private var previousNetwork: (time: TimeInterval, received: [UInt64: UInt64], sent: [UInt64: UInt64])?

    public init() {
        let levels = Self.perfLevels()
        self.levels = levels
        levelByCPU = Self.clusterTypes().flatMap {
            CPUClusters.assign(clusterTypeByCPU: $0, perfLevelCounts: levels.map(\.cpuCount))
        }
    }

    deinit { mach_port_deallocate(mach_task_self_, host) }

    public func sample() -> UsageReading {
        var reading = UsageReading()
        sampleCPU(into: &reading)
        reading.gpuBusy = UsageRates.gpuFraction(percent: Self.gpuUtilizationPercent())
        sampleDisk(into: &reading)
        sampleNetwork(into: &reading)
        return reading
    }

    // MARK: CPU

    private func sampleCPU(into reading: inout UsageReading) {
        guard let ticks = CPUActivitySampler.ticks(host: host) else { return }
        defer { previousTicks = ticks }
        let cpuCount = ticks.count / CPUActivity.statesPerCPU
        // The device tree has to describe exactly the CPUs the kernel counts.
        let mapping = levelByCPU.flatMap { $0.count == cpuCount ? $0 : nil }
        guard let previous = previousTicks, previous.count == ticks.count else {
            reading.pending.append("cpu")
            reading.coreGroups = mapping.map { _ in levels.map { .init(name: $0.name, cpuCount: $0.cpuCount, busy: nil) } }
            return
        }
        reading.cpuBusy = CPUActivity.busyFraction(previous: previous, current: ticks)
        if let mapping {
            reading.coreGroups = levels.indices.map { level in
                let cpus = Set(mapping.filter { $0.value == level }.keys)
                return .init(name: levels[level].name, cpuCount: levels[level].cpuCount,
                             busy: CPUActivity.busyFraction(previous: previous, current: ticks, cpus: cpus))
            }
        }
    }

    private static func perfLevels() -> [(name: String, cpuCount: Int)] {
        guard let count = sysctlInt("hw.nperflevels"), count > 0, count <= 8 else { return [] }
        var result: [(name: String, cpuCount: Int)] = []
        for level in 0..<count {
            guard let cpus = sysctlInt("hw.perflevel\(level).logicalcpu"), cpus > 0 else { return [] }
            result.append((name: sysctlString("hw.perflevel\(level).name") ?? "第 \(level + 1) 类", cpuCount: cpus))
        }
        return result
    }

    /// Logical CPU id → "cluster-type" letter from the device tree's cpus node.
    private static func clusterTypes() -> [Int: String]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [Int: String] = [:]
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            guard let id = property(cpu, "logical-cpu-id") as? Int,
                  let data = property(cpu, "cluster-type") as? Data else { return nil }
            let letter = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            guard !letter.isEmpty, result[id] == nil else { return nil }
            result[id] = letter
        }
        return result.isEmpty ? nil : result
    }

    // MARK: GPU

    /// The busiest accelerator's "Device Utilization %"; nil when none reports it.
    private static func gpuUtilizationPercent() -> Double? {
        var values: [Double] = []
        forEachService("IOAccelerator") { service in
            if let stats = property(service, "PerformanceStatistics") as? [String: Any],
               let value = stats["Device Utilization %"] as? NSNumber {
                values.append(value.doubleValue)
            }
        }
        return values.max()
    }

    // MARK: Disk

    private func sampleDisk(into reading: inout UsageReading) {
        var read: [UInt64: UInt64] = [:]
        var write: [UInt64: UInt64] = [:]
        Self.forEachService("IOBlockStorageDriver") { driver in
            guard !Self.isVirtualDisk(driver),
                  let stats = Self.property(driver, "Statistics") as? [String: Any],
                  let bytesRead = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value,
                  let bytesWritten = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value else { return }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &id) == KERN_SUCCESS else { return }
            read[id] = bytesRead
            write[id] = bytesWritten
        }
        guard !read.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousDisk = (now, read, write) }
        if let previous = previousDisk {
            let seconds = now - previous.time
            reading.diskReadBytesPerSecond = UsageRates.summedPerSecond(previous: previous.read, current: read, seconds: seconds)
            reading.diskWriteBytesPerSecond = UsageRates.summedPerSecond(previous: previous.write, current: write, seconds: seconds)
        }
        if reading.diskReadBytesPerSecond == nil || reading.diskWriteBytesPerSecond == nil {
            reading.diskReadBytesPerSecond = nil
            reading.diskWriteBytesPerSecond = nil
            reading.pending.append("disk")
        }
    }

    /// Mounted disk images sit on a "Virtual Interface"; their reads also hit
    /// the real disk holding the image file, so counting them would double up.
    private static func isVirtualDisk(_ driver: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        guard let characteristics = property(parent, "Protocol Characteristics") as? [String: Any] else { return false }
        return characteristics["Physical Interconnect"] as? String == "Virtual Interface"
            || characteristics["Physical Interconnect Location"] as? String == "File"
    }

    // MARK: Network

    private func sampleNetwork(into reading: inout UsageReading) {
        guard let counters = Self.interfaceCounters() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousNetwork = (now, counters.received, counters.sent) }
        if let previous = previousNetwork {
            let seconds = now - previous.time
            reading.networkReceivedBytesPerSecond = UsageRates.summedPerSecond(previous: previous.received, current: counters.received, seconds: seconds)
            reading.networkSentBytesPerSecond = UsageRates.summedPerSecond(previous: previous.sent, current: counters.sent, seconds: seconds)
        }
        if reading.networkReceivedBytesPerSecond == nil || reading.networkSentBytesPerSecond == nil {
            reading.networkReceivedBytesPerSecond = nil
            reading.networkSentBytesPerSecond = nil
            reading.pending.append("network")
        }
    }

    /// 64-bit byte counters of the physical ("en…") interfaces: Ethernet and
    /// Wi-Fi. Loopback, VPN/proxy tunnels (utun), bridges and AWDL are left
    /// out, since tunnel traffic is the same bytes again on a physical port.
    private static func interfaceCounters() -> (received: [UInt64: UInt64], sent: [UInt64: UInt64])? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        var received: [UInt64: UInt64] = [:]
        var sent: [UInt64: UInt64] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil,
                       String(cString: name).hasPrefix("en") {
                        let index = UInt64(message.ifm_index)
                        received[index] = message.ifm_data.ifi_ibytes
                        sent[index] = message.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return received.isEmpty ? nil : (received, sent)
    }

    // MARK: Helpers

    private static func forEachService(_ className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }
}
