import XCTest
@testable import WattsUpCore

final class PowerBreakdownTests: XCTestCase {
    func testTotalGPUAndCPUEstimateConserve() {
        // Idle values from the 2026-10-03 calibration: PSTR 33.13, PP0b 2.52, GPU 7.40.
        let r = PowerBreakdown.make(totalWatts: 33.13, cpuEstimateWatts: 2.52, gpuWatts: 7.40)
        XCTAssertEqual(r.plotted.map(\.kind), [.cpu, .gpu, .other])
        XCTAssertEqual(r.plottedSum, 33.13, accuracy: 1e-9)
        XCTAssertEqual(r.branch(.other)?.watts ?? -1, 33.13 - 2.52 - 7.40, accuracy: 1e-9)
        XCTAssertEqual(r.branch(.cpu)?.status, .estimated)
        XCTAssertEqual(r.branch(.gpu)?.status, .measured)
    }

    func testOnlyReadablePartsAreListed() {
        // ANE and DRAM have no readable power on M6 / macOS 27: they are not listed at all.
        let r = PowerBreakdown.make(totalWatts: 20, cpuEstimateWatts: 3, gpuWatts: 1)
        XCTAssertEqual(PowerBranchKind.allCases, [.cpu, .gpu, .other])
        XCTAssertEqual((r.plotted + r.unplotted).map(\.kind), [.cpu, .gpu, .other])
        XCTAssertTrue(r.unplotted.isEmpty)
    }

    func testAbsentSensorIsHiddenNotShownAsBroken() {
        let r = PowerBreakdown.make(totalWatts: 20, cpuEstimateWatts: nil, gpuWatts: 4, cpuState: .absent)
        XCTAssertEqual(r.branch(.cpu)?.status, .unavailable)
        XCTAssertEqual(r.branch(.cpu)?.isHidden, true)
        XCTAssertEqual(r.branch(.other)?.watts, 16)
    }

    func testFailedReadIsShownAndItsPowerStaysInOther() {
        let r = PowerBreakdown.make(totalWatts: 20, cpuEstimateWatts: nil, gpuWatts: 4, cpuState: .failed)
        XCTAssertEqual(r.branch(.cpu)?.status, .failed)
        XCTAssertEqual(r.branch(.cpu)?.statusText, "读取失败")
        XCTAssertEqual(r.branch(.cpu)?.isHidden, false)
        XCTAssertEqual(r.branch(.other)?.watts, 16)
    }

    func testStaleReadingIsNotPlottedEvenWithAValue() {
        let r = PowerBreakdown.make(totalWatts: 20, cpuEstimateWatts: 3, gpuWatts: 0, gpuState: .stale)
        XCTAssertEqual(r.branch(.gpu)?.status, .stale)
        XCTAssertEqual(r.branch(.gpu)?.statusText, "数据未更新")
        XCTAssertNil(r.branch(.gpu)?.watts)
        XCTAssertEqual(r.plotted.map(\.kind), [.cpu, .other])
        XCTAssertEqual(r.branch(.other)?.watts, 17)
    }

    func testPendingWinsOverSensorStateForGPU() {
        let r = PowerBreakdown.make(totalWatts: 20, cpuEstimateWatts: 3, gpuWatts: nil, gpuPending: true, gpuState: .failed)
        XCTAssertEqual(r.branch(.gpu)?.status, .pending)
    }

    func testCPUEstimateGivesWayFirstWhenSumExceedsTotal() {
        let r = PowerBreakdown.make(totalWatts: 10, cpuEstimateWatts: 8, gpuWatts: 4)
        XCTAssertEqual(r.plotted.map(\.kind), [.gpu, .other])
        XCTAssertEqual(r.branch(.cpu)?.status, .withheld)
        XCTAssertNil(r.branch(.cpu)?.watts)
        XCTAssertEqual(r.branch(.other)?.watts, 6)
    }

    func testGPUAboveTotalIsWithheldButCPUCanStay() {
        let r = PowerBreakdown.make(totalWatts: 10, cpuEstimateWatts: 3, gpuWatts: 12)
        XCTAssertEqual(r.branch(.gpu)?.status, .withheld)
        XCTAssertEqual(r.branch(.cpu)?.watts, 3)
        XCTAssertEqual(r.branch(.other)?.watts, 7)
        XCTAssertEqual(r.plottedSum, 10, accuracy: 1e-9)
    }

    func testPendingGPUBaselineIsNotZero() {
        let r = PowerBreakdown.make(totalWatts: 16, cpuEstimateWatts: 2, gpuWatts: nil, gpuPending: true)
        XCTAssertEqual(r.branch(.gpu)?.status, .pending)
        XCTAssertNil(r.branch(.gpu)?.watts)
        XCTAssertEqual(r.branch(.other)?.watts, 14)
    }

    func testHiddenBranchesStayInOther() {
        let r = PowerBreakdown.make(totalWatts: 20, cpuEstimateWatts: 5, gpuWatts: 2, showCPU: false, showGPU: true)
        XCTAssertNil(r.branch(.cpu), "a switched-off branch is not listed at all")
        XCTAssertEqual(r.branch(.other)?.watts, 18)
        let none = PowerBreakdown.make(totalWatts: 20, cpuEstimateWatts: 5, gpuWatts: 2, showCPU: false, showGPU: false)
        XCTAssertEqual(none.plotted.map(\.kind), [.other])
        XCTAssertEqual(none.branch(.other)?.watts, 20)
    }

    func testUnknownTotalLeavesOtherUnknown() {
        let r = PowerBreakdown.make(totalWatts: nil, cpuEstimateWatts: 2, gpuWatts: 1)
        XCTAssertNil(r.totalWatts)
        XCTAssertNil(r.branch(.other)?.watts)
        XCTAssertEqual(r.branch(.cpu)?.watts, 2)
        let invalid = PowerBreakdown.make(totalWatts: .nan, cpuEstimateWatts: -1, gpuWatts: .infinity)
        XCTAssertNil(invalid.totalWatts)
        XCTAssertEqual(invalid.branch(.cpu)?.status, .unavailable)
        XCTAssertEqual(invalid.branch(.gpu)?.status, .unavailable)
    }

    func testUnplottedOrderIsStable() {
        let r = PowerBreakdown.make(totalWatts: 5, cpuEstimateWatts: 6, gpuWatts: 9)
        XCTAssertEqual(r.unplotted.map(\.kind), [.cpu, .gpu])
    }
}
