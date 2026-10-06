import XCTest
@testable import WattsUpCore

final class UsageTests: XCTestCase {
    func testSummedRateCountsOnlyDevicesInBothSnapshots() {
        let before: [UInt64: UInt64] = [1: 1_000, 2: 5_000]
        let after: [UInt64: UInt64] = [1: 3_000, 2: 9_000, 3: 1_000_000]
        // Device 3 just appeared: its lifetime total is not a rate.
        XCTAssertEqual(UsageRates.summedPerSecond(previous: before, current: after, seconds: 2) ?? -1, 3_000, accuracy: 1e-9)
    }

    func testSummedRateSkipsCountersThatWentBackwards() {
        let before: [UInt64: UInt64] = [1: 10_000, 2: 100]
        let after: [UInt64: UInt64] = [1: 50, 2: 1_100]
        XCTAssertEqual(UsageRates.summedPerSecond(previous: before, current: after, seconds: 1) ?? -1, 1_000, accuracy: 1e-9)
    }

    func testSummedRateWithoutCommonDevicesOrTimeIsUnknown() {
        XCTAssertNil(UsageRates.summedPerSecond(previous: [1: 0], current: [2: 10], seconds: 1))
        XCTAssertNil(UsageRates.summedPerSecond(previous: [:], current: [1: 10], seconds: 1))
        XCTAssertNil(UsageRates.summedPerSecond(previous: [1: 0], current: [1: 10], seconds: 0))
        XCTAssertNil(UsageRates.summedPerSecond(previous: [1: 0], current: [1: 10], seconds: .nan))
        // Idle is a real zero, not unknown.
        XCTAssertEqual(UsageRates.summedPerSecond(previous: [1: 10], current: [1: 10], seconds: 1), 0)
    }

    func testSingleCounterRate() {
        XCTAssertEqual(UsageRates.perSecond(previous: 100, current: 300, seconds: 2), 100)
        XCTAssertNil(UsageRates.perSecond(previous: 300, current: 100, seconds: 2))
        XCTAssertNil(UsageRates.perSecond(previous: 0, current: 100, seconds: 0))
    }

    func testGPUPercentIsValidated() {
        XCTAssertEqual(UsageRates.gpuFraction(percent: 37), 0.37)
        XCTAssertEqual(UsageRates.gpuFraction(percent: 0), 0)
        XCTAssertNil(UsageRates.gpuFraction(percent: nil))
        XCTAssertNil(UsageRates.gpuFraction(percent: 101))
        XCTAssertNil(UsageRates.gpuFraction(percent: -1))
        XCTAssertNil(UsageRates.gpuFraction(percent: .infinity))
    }

    func testBusyFractionOverASubsetOfCPUs() {
        // Three CPUs: busy 80/100, 10/100, 50/100.
        let before: [UInt32] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let after: [UInt32] = [70, 10, 20, 0, 5, 5, 90, 0, 25, 25, 50, 0]
        XCTAssertEqual(CPUActivity.busyFraction(previous: before, current: after, cpus: [0]) ?? -1, 0.8, accuracy: 1e-12)
        XCTAssertEqual(CPUActivity.busyFraction(previous: before, current: after, cpus: [1, 2]) ?? -1, 0.3, accuracy: 1e-12)
        XCTAssertNil(CPUActivity.busyFraction(previous: before, current: after, cpus: []))
        XCTAssertNil(CPUActivity.busyFraction(previous: before, current: after, cpus: [3]))
    }

    func testClustersMatchedByCountOnAThreeLevelChip() {
        // M6 Mac mini: device tree E×6 (cpu0–5), P×2 (cpu6–7), M×4 (cpu8–11);
        // kernel levels Super 2, Performance 4, Efficiency 6.
        var letters: [Int: String] = [:]
        for cpu in 0..<6 { letters[cpu] = "E" }
        for cpu in 6..<8 { letters[cpu] = "P" }
        for cpu in 8..<12 { letters[cpu] = "M" }
        let result = CPUClusters.assign(clusterTypeByCPU: letters, perfLevelCounts: [2, 4, 6])
        XCTAssertEqual(result?[0], 2)
        XCTAssertEqual(result?[5], 2)
        XCTAssertEqual(result?[6], 0)
        XCTAssertEqual(result?[8], 1)
        XCTAssertEqual(result?.count, 12)
    }

    func testClassicTwoLevelChipWithEqualCounts() {
        let letters: [Int: String] = [0: "E", 1: "E", 2: "E", 3: "E", 4: "P", 5: "P", 6: "P", 7: "P"]
        let result = CPUClusters.assign(clusterTypeByCPU: letters, perfLevelCounts: [4, 4])
        XCTAssertEqual(result?[0], 1)
        XCTAssertEqual(result?[4], 0)
    }

    func testAmbiguousOrIncompleteLayoutsAreNotSplit() {
        // Equal counts and unknown letters: no way to tell which is which.
        XCTAssertNil(CPUClusters.assign(clusterTypeByCPU: [0: "A", 1: "A", 2: "B", 3: "B"], perfLevelCounts: [2, 2]))
        // A CPU missing from the device tree.
        XCTAssertNil(CPUClusters.assign(clusterTypeByCPU: [0: "E", 1: "P"], perfLevelCounts: [1, 2]))
        // More letters than levels.
        XCTAssertNil(CPUClusters.assign(clusterTypeByCPU: [0: "E", 1: "P", 2: "M"], perfLevelCounts: [1, 2]))
        // Counts that do not line up with any level.
        XCTAssertNil(CPUClusters.assign(clusterTypeByCPU: [0: "E", 1: "E", 2: "P"], perfLevelCounts: [1, 1, 1]))
        XCTAssertNil(CPUClusters.assign(clusterTypeByCPU: [:], perfLevelCounts: []))
    }

    func testCoreTitles() {
        XCTAssertEqual(CPUClusters.title(forLevelName: "Super"), "超级核")
        XCTAssertEqual(CPUClusters.title(forLevelName: "Performance"), "性能核")
        XCTAssertEqual(CPUClusters.title(forLevelName: "Efficiency"), "能效核")
        XCTAssertEqual(CPUClusters.title(forLevelName: "Turbo"), "Turbo")
    }

    func testRateAndPercentFormatting() {
        XCTAssertEqual(Units.rate(0), "0 KB/s")
        XCTAssertEqual(Units.rate(512_000), "512 KB/s")
        XCTAssertEqual(Units.rate(12_345_678), "12.3 MB/s")
        XCTAssertEqual(Units.rate(456_000_000), "456 MB/s")
        XCTAssertEqual(Units.rate(6_100_000_000), "6.10 GB/s")
        XCTAssertEqual(Units.rate(nil), "未知")
        XCTAssertEqual(Units.rate(-1), "未知")
        XCTAssertEqual(Units.percent(0.374), "37%")
        XCTAssertEqual(Units.percent(1.2), "100%")
        XCTAssertEqual(Units.percent(nil), "未知")
    }

    func testUnknownStaysUnknownThroughJSON() throws {
        let reading = UsageReading(cpuBusy: 0.25, gpuBusy: nil, pending: ["disk"])
        let decoded = try JSONDecoder().decode(UsageReading.self, from: JSONEncoder().encode(reading))
        XCTAssertEqual(decoded, reading)
        XCTAssertNil(decoded.gpuBusy)
        XCTAssertNil(decoded.diskReadBytesPerSecond)
        XCTAssertTrue(decoded.isPending("disk"))
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertTrue(UsageReading().isEmpty)
        XCTAssertFalse(UsageReading(pending: ["cpu"]).isEmpty)
    }
}
