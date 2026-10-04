import XCTest
@testable import WattsUpCore

final class MemoryBandwidthTests: XCTestCase {
    private func buckets(_ counts: [Int64], step: Int = 4) -> [(name: String, count: Int64)] {
        counts.enumerated().map { (name: String(format: "%3dGB/s", ($0.offset + 1) * step), count: $0.element) }
    }

    func testParsesBucketNames() {
        XCTAssertEqual(MemoryBandwidth.upperEdge("  4GB/s"), 4)
        XCTAssertEqual(MemoryBandwidth.upperEdge("128GB/s"), 128)
        XCTAssertEqual(MemoryBandwidth.upperEdge("512MB/s"), 0.512)
        XCTAssertNil(MemoryBandwidth.upperEdge("IDLE"))
        XCTAssertNil(MemoryBandwidth.upperEdge("0GB/s"))
    }

    func testWeightedMidpoints() {
        // Half the windows in 0–4 GB/s (mid 2), half in 4–8 GB/s (mid 6) → 4 GB/s.
        let r = MemoryBandwidth.estimate(buckets([50, 50, 0, 0]))
        XCTAssertEqual(r?.gigabytesPerSecond ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(r?.atCeiling, false)
    }

    func testIdleHistogramFromThisMac() {
        // A real idle sample of AMCC RD+WR (counts per 4 GB/s bucket).
        var counts = [Int64](repeating: 0, count: 32)
        for (i, c) in [559, 2402, 906, 359, 154, 33, 5, 3, 2, 14, 2, 2, 7, 4, 1].enumerated() { counts[i] = Int64(c) }
        let r = MemoryBandwidth.estimate(buckets(counts))!
        XCTAssertEqual(r.gigabytesPerSecond, 8.0, accuracy: 0.5)
        XCTAssertFalse(r.atCeiling)
    }

    func testTopBucketMarksACeiling() {
        var counts = [Int64](repeating: 0, count: 32)
        counts[31] = 900
        counts[30] = 100
        let r = MemoryBandwidth.estimate(buckets(counts))!
        XCTAssertTrue(r.atCeiling)
        XCTAssertEqual(r.gigabytesPerSecond, 125.6, accuracy: 0.01)
    }

    func testRejectsEmptyOrUnparsableHistograms() {
        XCTAssertNil(MemoryBandwidth.estimate(buckets([0, 0, 0])))
        XCTAssertNil(MemoryBandwidth.estimate([(name: "IDLE", count: 5), (name: "  4GB/s", count: 5)]))
        XCTAssertNil(MemoryBandwidth.estimate(buckets([7])))
        XCTAssertNil(MemoryBandwidth.estimate([]))
    }
}
