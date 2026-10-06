import Foundation
import WattsUpCore

/// The app-independent transport model for CLI output and a future App Group
/// snapshot file. Missing readings remain nil across encoding and decoding.
public struct HardwareSnapshot: Codable, Sendable {
    public var schemaVersion: Int
    public let timestamp: Date
    public let power: PowerSample
    public let memory: MemorySample
    /// Additive v0.4 field: DRAM read+write bandwidth estimate (nil = unknown).
    public let memoryBandwidth: MemoryBandwidthReading?
    /// Additive v0.6 field: CPU/GPU/disk/network activity (nil = not sampled).
    public let usage: UsageReading?

    public init(timestamp: Date = Date(), power: PowerSample, memory: MemorySample,
                memoryBandwidth: MemoryBandwidthReading? = nil, usage: UsageReading? = nil) {
        self.schemaVersion = 1
        self.timestamp = timestamp
        self.power = power
        self.memory = memory
        self.memoryBandwidth = memoryBandwidth
        self.usage = usage
    }
}
