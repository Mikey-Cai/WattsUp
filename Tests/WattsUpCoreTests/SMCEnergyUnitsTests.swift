import XCTest
@testable import WattsUpCore

final class SMCEnergyUnitsTests: XCTestCase {
    func testEnergyDeltaUsesMeasuredElapsedTime() {
        XCTAssertEqual(SMCEnergyUnits.watts(delta: 4_000, unit: "mJ", elapsedSeconds: 2), 2)
        XCTAssertEqual(SMCEnergyUnits.watts(delta: 4_000_000, unit: "uJ", elapsedSeconds: 2), 2)
        XCTAssertEqual(SMCEnergyUnits.watts(delta: 4_000_000_000, unit: "nJ", elapsedSeconds: 2), 2)
        XCTAssertEqual(SMCEnergyUnits.watts(delta: 4, unit: "J", elapsedSeconds: 2), 2)
    }
    func testUnknownUnitsAndCounterResetRemainUnknown() {
        XCTAssertNil(SMCEnergyUnits.watts(delta: 20, unit: "W", elapsedSeconds: 2))
        XCTAssertNil(SMCEnergyUnits.watts(delta: -1, unit: "mJ", elapsedSeconds: 2))
        XCTAssertNil(SMCEnergyUnits.watts(delta: 20, unit: "mJ", elapsedSeconds: 0))
        XCTAssertNil(SMCEnergyUnits.watts(delta: 20, unit: "mJ", elapsedSeconds: .nan))
    }
}
