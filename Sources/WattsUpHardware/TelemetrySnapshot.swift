import Foundation
import WattsUpCore

/// The app-independent transport model for CLI output and a future App Group
/// snapshot file. Missing readings remain nil across encoding and decoding.
public struct HardwareSnapshot: Codable, Sendable {
    public var schemaVersion: Int
    public let timestamp: Date
    public let power: PowerSample
    public let memory: MemorySample

    public init(timestamp: Date = Date(), power: PowerSample, memory: MemorySample) {
        self.schemaVersion = 1
        self.timestamp = timestamp
        self.power = power
        self.memory = memory
    }
}
