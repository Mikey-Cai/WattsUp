import Foundation

/// DRAM read+write bandwidth estimated from the memory controller's PMP
/// histogram (IOReport "PMP" / "DCS BW" / "AMCC RD+WR"). Each state is a
/// bandwidth bucket named by its upper edge ("  4GB/s", "  8GB/s", …) and its
/// count is how many short sampling windows fell into it, so the average
/// bandwidth is the count-weighted mean of the bucket midpoints.
///
/// On an M6 Mac mini this tracked a measured memcpy load within about 10 %
/// (110 vs 101 GB/s with one thread, 126 vs 128 GB/s with eight). The top
/// bucket is 128 GB/s, so readings at the top are only a lower bound.
public struct MemoryBandwidthReading: Codable, Equatable, Sendable {
    /// Estimated average read+write bandwidth in GB/s (10^9 bytes per second).
    public let gigabytesPerSecond: Double
    /// Most windows sat in the highest bucket: the true figure may be higher.
    public let atCeiling: Bool

    public init(gigabytesPerSecond: Double, atCeiling: Bool) {
        self.gigabytesPerSecond = gigabytesPerSecond
        self.atCeiling = atCeiling
    }
}

public enum MemoryBandwidth {
    /// Upper edge in GB/s from a state name such as "  4GB/s" or "512MB/s".
    public static func upperEdge(_ name: String) -> Double? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for (suffix, scale) in [("GB/s", 1.0), ("MB/s", 0.001)] where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)),
                  value.isFinite, value > 0 else { return nil }
            return value * scale
        }
        return nil
    }

    /// - Parameter buckets: every state of the channel (including empty ones)
    ///   with this interval's residency delta.
    public static func estimate(_ buckets: [(name: String, count: Int64)]) -> MemoryBandwidthReading? {
        let parsed = buckets.compactMap { bucket in upperEdge(bucket.name).map { (edge: $0, count: max(0, bucket.count)) } }
            .sorted { $0.edge < $1.edge }
        guard parsed.count >= 2, parsed.count == buckets.count else { return nil }
        let total = parsed.reduce(Int64(0)) { $0 + $1.count }
        guard total > 0 else { return nil }
        var weighted = 0.0
        var lower = 0.0
        for bucket in parsed {
            weighted += (lower + bucket.edge) / 2 * Double(bucket.count)
            lower = bucket.edge
        }
        let top = parsed[parsed.count - 1]
        return MemoryBandwidthReading(gigabytesPerSecond: weighted / Double(total),
                                      atCeiling: Double(top.count) >= Double(total) * 0.5)
    }
}
