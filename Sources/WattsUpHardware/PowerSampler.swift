import Foundation
import WattsUpCore

public struct PowerComponent: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let watts: Double?
    public let source: String
    public let confirmed: Bool
}

public struct PowerSample: Codable, Sendable {
    public let timestamp: Date
    public let totalWatts: Double?
    public let totalSource: String
    public let components: [PowerComponent]
    public let unallocatedWatts: Double?
    public let channels: [EnergyChannelSample]
    public let availableChannels: [IOReportChannelDescriptor]
    /// Additive v0.2 field; optional so v0.1 snapshots remain decodable. Candidate
    /// sensors are retained as evidence even when they are excluded from the split.
    public let smcReadings: [SMCKeyReading]?
    /// Additive v0.3 field: IOReport only has its first baseline (GPU pending).
    public let energyBaselinePending: Bool?
    /// Additive v0.3.1 fields: sensor health across ticks and all-core CPU busy fraction.
    public let cpuState: SensorState?
    public let gpuState: SensorState?
    public let cpuBusyFraction: Double?
    public let diagnostics: [String]
}

/// Single-owner sampler: invoke on one serial queue. Connections and subscriptions
/// persist between ticks, while every delta dictionary is released in the C bridge.
public final class PowerSampler {
    private let smc = SMCReader()
    private let ioReport = IOReportReader()
    private let cpuActivity = CPUActivitySampler()
    private var cpuHealth = SensorHealth()
    private var gpuHealth = SensorHealth()

    public init() {}

    public func probe() -> SMCProbeReport { smc.probe() }

    public func sample() -> PowerSample {
        // These are observations, not independent addends. PZC0/PZC1 already
        // exceed PSTR together in the supplied idle and CPU-load samples, while
        // PDTR/PD0R and PPSM/PHPC are duplicate values in both samples.
        let candidateKeys = ["PSTR", "PP0b", "PZC0", "PZC1", "PPMR", "PHPC", "PPSM", "PDTR", "PD0R", "PMVC"]
        let readings = candidateKeys.map { smc.read($0) }
        let totalReading = readings[0]
        let total = SMCPowerAccounting.sensorWatts(type: totalReading.type, value: totalReading.value)
        let cpuReading = readings[1]
        let cpu = SMCPowerAccounting.sensorWatts(type: cpuReading.type, value: cpuReading.value)
        let energy = ioReport.sample()
        var diagnostics = energy.diagnostics
        if let error = totalReading.error { diagnostics.append("PSTR: \(error)") }
        if total == nil && totalReading.error == nil { diagnostics.append("PSTR has an unsupported type or implausible/non-finite power value; input power remains unknown.") }
        if let error = cpuReading.error { diagnostics.append("PP0b CPU estimate: \(error)") }
        if cpu == nil && cpuReading.error == nil { diagnostics.append("PP0b CPU estimate is unavailable: unsupported type or implausible/non-finite power value.") }

        func component(_ id: String, label: String, acceptedNames: Set<String>, confirmed: Bool) -> PowerComponent {
            let candidates = energy.channels.filter { acceptedNames.contains($0.name) && $0.group == "Energy Model" }
            guard candidates.count == 1, let channel = candidates.first, let watts = channel.watts,
                  watts.isFinite, watts >= 0, watts <= 2_000 else {
                if candidates.count > 1 { diagnostics.append("\(label): multiple matching IOReport rails; refusing to sum potentially overlapping parent/child channels.") }
                return PowerComponent(id: id, label: label, watts: nil, source: "IOReport 通道不可用", confirmed: false)
            }
            return PowerComponent(id: id, label: label, watts: watts,
                                  source: "IOReport / \(channel.name) / Δ\(channel.unit)÷Δt", confirmed: confirmed)
        }

        // v0.3: PCIe and USB/Thunderbolt rails are gone from the split. On a
        // Mac mini the PCIe "Energy" channels read ~0 and are not a complete
        // interface total; their power stays in the residual ("其他").
        let components = [
            PowerComponent(id: "cpu", label: "CPU（估计）", watts: cpu,
                           source: "AppleSMC / PP0b；本机分阶段测试中与 CPU 负载相关，物理边界与绝对误差未验证", confirmed: false),
            component("gpu", label: "GPU", acceptedNames: ["GPU Energy", "GPU"], confirmed: true)
        ]
        let now = ProcessInfo.processInfo.systemUptime
        let pending = ioReport.lastSampleWasBaseline
        let cpuState = cpuHealth.observe(cpu, at: now)
        // GPU energy can honestly read ~0 W for long stretches when the GPU is
        // power-gated, so only read failures are tracked for it, not repeats.
        let gpuState = pending ? SensorState.ok : gpuHealth.observe(components[1].watts, at: now, detectStale: false)
        if cpuState == .stale { diagnostics.append("PP0b has returned the identical value for 30 s; treated as not updating.") }
        let breakdown = PowerBreakdown.make(totalWatts: total, cpuEstimateWatts: cpu,
                                            gpuWatts: components[1].watts, gpuPending: pending,
                                            cpuState: cpuState, gpuState: gpuState)
        if breakdown.branch(.cpu)?.status == .withheld || breakdown.branch(.gpu)?.status == .withheld {
            diagnostics.append("Raw rails exceed instantaneous PSTR this tick; the inconsistent reading is withheld from the split instead of being rescaled.")
        }
        diagnostics.append("PP0b is a CPU-correlated proxy on this Mac; the calibration does not establish complete CPU coverage or disjointness from GPU/DRAM. ANE/DRAM have no trustworthy rail on M6/macOS 27 and are not shown.")
        diagnostics.append("PSTR has not been checked against a wall-plug meter. The residual is an arithmetic remainder (unattributed parts, losses, timing and model error); it is not a DRAM measurement.")
        let unallocated = breakdown.branch(.other)?.watts
        return PowerSample(timestamp: Date(), totalWatts: total, totalSource: "AppleSMC / PSTR",
                           components: components, unallocatedWatts: unallocated,
                           channels: energy.channels, availableChannels: ioReport.availableChannels,
                           smcReadings: readings, energyBaselinePending: pending,
                           cpuState: cpuState, gpuState: gpuState, cpuBusyFraction: cpuActivity.sample(),
                           diagnostics: diagnostics)
    }
}
