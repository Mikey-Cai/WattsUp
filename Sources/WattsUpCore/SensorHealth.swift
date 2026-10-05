import Foundation

/// What a sensor has been doing across recent ticks, so the UI can tell
/// "this Mac does not have it" (hide it) from "it broke just now" (say so).
public enum SensorState: String, Codable, Sendable {
    case ok
    /// Never produced a valid reading in this session: treated as not present.
    case absent
    /// Produced valid readings before, but this tick's read failed.
    case failed
    /// Has returned the exact same value for a while: the counter is not updating.
    case stale
}

/// Single-owner tracker for one sensor; call `observe` once per sample.
public struct SensorHealth: Sendable {
    /// A value must repeat for at least this long, and over at least
    /// `minRepeats` samples, before it counts as stale. SMC power sensors
    /// refresh more slowly than WattsUp polls: in the 2026-10-03 calibration
    /// PP0b returned the identical float two or three times in a row (about
    /// 2–3 s), so the defaults leave a wide margin above that.
    public let staleSeconds: TimeInterval
    public let minRepeats: Int
    private var everValid = false
    private var last: Double?
    private var sameSince: TimeInterval = 0
    private var repeats = 0

    public init(staleSeconds: TimeInterval = 30, minRepeats: Int = 5) {
        self.staleSeconds = staleSeconds
        self.minRepeats = minRepeats
    }

    /// - Parameters:
    ///   - value: this tick's reading; nil, NaN or negative means the read failed.
    ///   - time: a monotonic timestamp in seconds.
    ///   - detectStale: off for energy-delta counters such as GPU energy, whose
    ///     honest idle reading can be 0 W tick after tick.
    public mutating func observe(_ value: Double?, at time: TimeInterval, detectStale: Bool = true) -> SensorState {
        guard let value, value.isFinite, value >= 0 else {
            last = nil
            repeats = 0
            return everValid ? .failed : .absent
        }
        everValid = true
        if let last, value == last {
            repeats += 1
        } else {
            last = value
            sameSince = time
            repeats = 1
        }
        guard detectStale else { return .ok }
        return repeats >= minRepeats && time - sameSince >= staleSeconds ? .stale : .ok
    }
}
