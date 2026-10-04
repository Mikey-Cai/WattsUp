import XCTest
@testable import WattsUpCore

final class CPUActivityTests: XCTestCase {
    func testBusyFractionAcrossCores() {
        // Two CPUs, ticks are user, system, idle, nice.
        let before: [UInt32] = [100, 50, 850, 0, 10, 10, 980, 0]
        let after: [UInt32] = [160, 70, 870, 0, 20, 10, 1070, 0]
        // CPU0: busy 80 of 100; CPU1: busy 10 of 100 → 90 / 200.
        XCTAssertEqual(CPUActivity.busyFraction(previous: before, current: after) ?? -1, 0.45, accuracy: 1e-12)
    }

    func testCountersThatWrapAround() {
        let before: [UInt32] = [UInt32.max - 9, 0, 0, 0]
        let after: [UInt32] = [10, 0, 20, 0]
        // user advanced 20 across the wrap, idle 20.
        XCTAssertEqual(CPUActivity.busyFraction(previous: before, current: after) ?? -1, 0.5, accuracy: 1e-12)
    }

    func testMismatchedOrIdleSnapshotsGiveNil() {
        XCTAssertNil(CPUActivity.busyFraction(previous: [1, 2, 3, 4], current: [1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertNil(CPUActivity.busyFraction(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]))
        XCTAssertNil(CPUActivity.busyFraction(previous: [], current: []))
        XCTAssertNil(CPUActivity.busyFraction(previous: [1, 2, 3], current: [1, 2, 4]))
    }
}
