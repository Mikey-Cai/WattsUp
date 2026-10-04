import CSensors
import Foundation
import WattsUpCore

/// DRAM bandwidth from the PMP histogram; works as an ordinary user, no helper.
/// The first call only captures a baseline. Single owner: call from one queue.
public final class MemoryBandwidthSampler {
    private var report: OpaquePointer?
    private var buckets = [WUStateBucket](repeating: WUStateBucket(), count: 128)
    public let diagnostic: String?

    public init() {
        var error = [CChar](repeating: 0, count: 512)
        report = error.withUnsafeMutableBufferPointer { wu_state_open("PMP", "DCS BW", "AMCC RD+WR", $0.baseAddress, $0.count) }
        diagnostic = report == nil ? "PMP bandwidth: \(String(cString: error))" : nil
    }

    deinit { if let report { wu_state_close(report) } }

    public func sample() -> MemoryBandwidthReading? {
        guard let report else { return nil }
        var count = 0
        var error = [CChar](repeating: 0, count: 256)
        let result = buckets.withUnsafeMutableBufferPointer { output in
            error.withUnsafeMutableBufferPointer { message in
                wu_state_sample(report, output.baseAddress, output.count, &count, message.baseAddress, message.count)
            }
        }
        guard result == 0 else { return nil }
        let pairs = buckets.prefix(count).map { bucket -> (name: String, count: Int64) in
            var bucket = bucket
            let name = withUnsafePointer(to: &bucket.name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            return (name: name, count: bucket.count)
        }
        return MemoryBandwidth.estimate(pairs)
    }
}
