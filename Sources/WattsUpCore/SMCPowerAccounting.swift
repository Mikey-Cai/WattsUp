import Foundation

public struct SMCPowerAllocation: Equatable, Sendable {
    public let canAttributeComponents: Bool
    public let unallocatedWatts: Double?
}

public enum SMCPowerAccounting {
    /// The calibration uses SMC float power sensors. Do not reinterpret a flag,
    /// counter or an unsupported payload as a watt reading because its key starts P.
    public static func sensorWatts(type: String, value: Double?) -> Double? {
        guard type == "flt ", let value, value.isFinite, (0...2_000).contains(value) else { return nil }
        return value
    }

    /// Missing branches remain within the residual. Inconsistent scopes/windows
    /// close attribution instead of clipping or proportionally rescaling readings.
    public static func allocation(totalWatts: Double?, knownComponents: [Double]) -> SMCPowerAllocation {
        guard knownComponents.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return SMCPowerAllocation(canAttributeComponents: false,
                                      unallocatedWatts: totalWatts.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
        guard let totalWatts, totalWatts.isFinite, totalWatts >= 0 else {
            return SMCPowerAllocation(canAttributeComponents: true, unallocatedWatts: nil)
        }
        let sum = knownComponents.reduce(0, +)
        guard sum.isFinite, sum <= totalWatts else {
            return SMCPowerAllocation(canAttributeComponents: false, unallocatedWatts: totalWatts)
        }
        return SMCPowerAllocation(canAttributeComponents: true, unallocatedWatts: totalWatts - sum)
    }
}
