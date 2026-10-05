import Darwin
import Foundation
import WattsUpCore

/// All-core CPU busy fraction from the kernel's per-CPU tick counters.
/// Works inside the App Sandbox and needs no root helper.
public final class CPUActivitySampler {
    private let host = mach_host_self()
    private var previous: [UInt32]?

    public init() {}

    // mach_host_self() hands out a send-right reference each time it is called.
    deinit { mach_port_deallocate(mach_task_self_, host) }

    /// Busy fraction (0…1) since the previous call; nil on the first call or on failure.
    public func sample() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = ticks }
        guard let previous else { return nil }
        return CPUActivity.busyFraction(previous: previous, current: ticks)
    }
}
