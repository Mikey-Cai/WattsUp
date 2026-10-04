import Darwin
import Dispatch
import Foundation
import WattsUpCore

/// Uses ordinary user-mode Mach/sysctl calls. It does not request root or a helper.
public final class MemorySampler {
    private let pressureQueue = DispatchQueue(label: "io.github.mikey-cai.wattsup.memory-pressure", qos: .utility)
    private let pressureLock = NSLock()
    private var lastEventPressure: MemoryPressureLevel = .unknown
    private var lastEventTimestamp: Date?
    private let pressureSource: DispatchSourceMemoryPressure

    public init() {
        pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: pressureQueue
        )
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let value = MemoryPressureLevel.fromDispatchFlags(self.pressureSource.data.rawValue)
            self.pressureLock.lock()
            self.lastEventPressure = value
            self.lastEventTimestamp = Date()
            self.pressureLock.unlock()
        }
        pressureSource.resume()
    }

    deinit { pressureSource.cancel() }

    public func sample() -> MemorySample {
        let timestamp = Date()
        var errors: [String] = []
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        let sampledPageSize: UInt64?
        if pageResult == KERN_SUCCESS, pageSize > 0 {
            sampledPageSize = UInt64(pageSize)
        } else {
            sampledPageSize = nil
            errors.append("host_page_size: \(machError(pageResult))")
        }

        var physicalBytes: UInt64 = 0
        var physicalLength = MemoryLayout<UInt64>.size
        let physicalResult = sysctlbyname("hw.memsize", &physicalBytes, &physicalLength, nil, 0)
        let sampledPhysical: UInt64?
        if physicalResult == 0, physicalLength == MemoryLayout<UInt64>.size, physicalBytes > 0 {
            sampledPhysical = physicalBytes
        } else {
            let physicalError = physicalResult == 0 ? "无效的返回结构" : posixError()
            // ProcessInfo asks the OS for the installed physical size, not a fixed 24 GB constant.
            let fallback = ProcessInfo.processInfo.physicalMemory
            sampledPhysical = fallback > 0 ? fallback : nil
            errors.append("hw.memsize: \(physicalError); 使用 ProcessInfo.physicalMemory 回退")
        }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let statsResult = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                host_statistics64(host, HOST_VM_INFO64, raw, &count)
            }
        }
        var raw: MemoryPageCounts?
        var breakdown: MemoryBreakdown?
        if statsResult == KERN_SUCCESS {
            let counts = MemoryPageCounts(
                free: UInt64(stats.free_count), active: UInt64(stats.active_count), inactive: UInt64(stats.inactive_count),
                wired: UInt64(stats.wire_count), purgeable: UInt64(stats.purgeable_count),
                speculative: UInt64(stats.speculative_count), compressor: UInt64(stats.compressor_page_count),
                external: UInt64(stats.external_page_count), internal: UInt64(stats.internal_page_count),
                uncompressedInCompressor: stats.total_uncompressed_pages_in_compressor
            )
            raw = counts
            if let sampledPhysical, let sampledPageSize {
                do {
                    breakdown = try MemoryAccounting.calculate(raw: counts, physicalBytes: sampledPhysical, pageSize: sampledPageSize)
                } catch { errors.append("内存口径: \(error)") }
            }
        } else { errors.append("host_statistics64: \(machError(statsResult))") }

        var swap = xsw_usage()
        var swapLength = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapLength, nil, 0)
        let swapUsed: UInt64?
        let swapTotal: UInt64?
        if swapResult == 0, swapLength == MemoryLayout<xsw_usage>.size,
           swap.xsu_used <= swap.xsu_total, swap.xsu_avail <= swap.xsu_total {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        } else {
            swapUsed = nil
            swapTotal = nil
            errors.append("vm.swapusage: \(swapResult == 0 ? "无效的返回结构" : posixError())")
        }

        var pressureValue: Int32 = 0
        var pressureLength = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureValue, &pressureLength, nil, 0)
        var pressure = MemoryPressureLevel.unknown
        var pressureMethod = "unavailable"
        var pressureTimestamp: Date?
        if pressureResult == 0, pressureLength == MemoryLayout<Int32>.size {
            pressure = .fromKernelLevel(pressureValue)
            if pressure != .unknown {
                pressureMethod = "kern.memorystatus_vm_pressure_level"
                pressureTimestamp = timestamp
            } else { errors.append("kern.memorystatus_vm_pressure_level: 未识别的值 \(pressureValue)") }
        } else { errors.append("kern.memorystatus_vm_pressure_level: \(pressureResult == 0 ? "无效的返回结构" : posixError())") }
        if pressure == .unknown {
            pressureLock.lock()
            pressure = lastEventPressure
            pressureTimestamp = lastEventTimestamp
            pressureLock.unlock()
            if pressure != .unknown { pressureMethod = "dispatch.memoryPressure.lastObservedEvent" }
        }

        return MemorySample(
            timestamp: timestamp, physicalBytes: sampledPhysical, pageSize: sampledPageSize,
            breakdown: breakdown, swapUsedBytes: swapUsed, swapTotalBytes: swapTotal,
            pressure: pressure, pressureSource: pressureMethod, pressureTimestamp: pressureTimestamp,
            errors: errors, raw: raw
        )
    }

    private func posixError() -> String { String(cString: strerror(errno)) }
    private func machError(_ value: kern_return_t) -> String {
        String(cString: mach_error_string(value)) + " (\(value))"
    }
}
