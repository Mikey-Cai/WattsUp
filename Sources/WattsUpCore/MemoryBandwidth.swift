import Foundation

/// DRAM read+write bandwidth estimated from the memory controller's PMP
/// histogram (IOReport "PMP" / "DCS BW" / "AMCC RD+WR"). Each state is a
/// bandwidth bucket named by its upper edge ("  4GB/s", "  8GB/s", …) and its
/// count is how many short sampling windows fell into it, so the average
/// bandwidth is the count-weighted mean of the bucket midpoints.
///
/// On an M6 Mac mini two memcpy comparisons came out at 110 vs 101 GB/s (one
/// thread, +9 %) and 126 vs 128 GB/s (eight threads, −2 %); two runs are not a
/// general accuracy figure. The highest bucket ends at 128 GB/s, so its
/// midpoint (126) caps the estimate: time spent there means the true figure
/// may be higher, by an unknown amount.
public struct MemoryBandwidthReading: Codable, Equatable, Sendable {
    /// Midpoint estimate of the average read+write bandwidth, in GB/s (10^9 B/s).
    public let gigabytesPerSecond: Double
    /// Bounds implied by the bucket edges alone (quantisation only, not the
    /// whole measurement chain): every window somewhere inside its bucket.
    public let lowerBound: Double
    public let upperBound: Double
    /// Share of windows in the highest bucket (0…1).
    public let topBucketFraction: Double

    /// Enough windows reached the highest bucket that the estimate may be
    /// noticeably low. Short bursts put 0.1–4 % of windows there even at
    /// 5–50 GB/s on M6; even if those windows ran at ~170 GB/s (about the
    /// platform's theoretical peak) instead of the 126 GB/s midpoint, 4 % of
    /// them would add under 2 GB/s, i.e. less than the bucket rounding. From
    /// 5 % on, the hidden part can exceed that, so the UI says so.
    public var mayBeLow: Bool { topBucketFraction >= 0.05 }

    public init(gigabytesPerSecond: Double, lowerBound: Double, upperBound: Double, topBucketFraction: Double) {
        self.gigabytesPerSecond = gigabytesPerSecond
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.topBucketFraction = topBucketFraction
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
    /// - Returns: nil when the interval is not a complete, valid histogram: a
    ///   negative delta (counter reset), an unparsable or duplicate bucket, or a
    ///   total that overflows. The C layer has already moved to a new baseline,
    ///   so the next interval can still produce a reading.
    public static func estimate(_ buckets: [(name: String, count: Int64)]) -> MemoryBandwidthReading? {
        guard buckets.count >= 2, buckets.allSatisfy({ $0.count >= 0 }) else { return nil }
        let parsed = buckets.compactMap { bucket in upperEdge(bucket.name).map { (edge: $0, count: bucket.count) } }
            .sorted { $0.edge < $1.edge }
        guard parsed.count == buckets.count else { return nil }
        var total: Int64 = 0
        for bucket in parsed {
            let (sum, overflow) = total.addingReportingOverflow(bucket.count)
            guard !overflow else { return nil }
            total = sum
        }
        guard total > 0 else { return nil }
        var mid = 0.0, low = 0.0, high = 0.0
        var lower = 0.0
        for bucket in parsed {
            guard bucket.edge > lower else { return nil }
            let share = Double(bucket.count) / Double(total)
            mid += (lower + bucket.edge) / 2 * share
            low += lower * share
            high += bucket.edge * share
            lower = bucket.edge
        }
        guard mid.isFinite, low.isFinite, high.isFinite else { return nil }
        return MemoryBandwidthReading(gigabytesPerSecond: mid, lowerBound: low, upperBound: high,
                                      topBucketFraction: Double(parsed[parsed.count - 1].count) / Double(total))
    }
}
