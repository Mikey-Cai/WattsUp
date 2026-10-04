import XCTest
@testable import WattsUpCore

final class SMCPowerAccountingTests: XCTestCase {
    func testOnlyPlausibleFloatPowerSensorsAreAccepted() {
        XCTAssertEqual(SMCPowerAccounting.sensorWatts(type: "flt ", value: 14.134708404541016), 14.134708404541016)
        XCTAssertEqual(SMCPowerAccounting.sensorWatts(type: "flt ", value: 0), 0)
        XCTAssertNil(SMCPowerAccounting.sensorWatts(type: "ui32", value: 14))
        XCTAssertNil(SMCPowerAccounting.sensorWatts(type: "flt ", value: nil))
        XCTAssertNil(SMCPowerAccounting.sensorWatts(type: "flt ", value: .nan))
        XCTAssertNil(SMCPowerAccounting.sensorWatts(type: "flt ", value: .infinity))
        XCTAssertNil(SMCPowerAccounting.sensorWatts(type: "flt ", value: -0.1))
        XCTAssertNil(SMCPowerAccounting.sensorWatts(type: "flt ", value: 2_001))
    }

    func testDisablingAnEstimateReturnsItsReadingToResidual() {
        let total = 28.21219825744629
        let cpuEstimate = 5.834430694580078
        let gpu = 4.5
        let enabled = SMCPowerAccounting.allocation(totalWatts: total, knownComponents: [cpuEstimate, gpu])
        let disabled = SMCPowerAccounting.allocation(totalWatts: total, knownComponents: [gpu])
        XCTAssertTrue(enabled.canAttributeComponents)
        XCTAssertEqual(disabled.unallocatedWatts! - enabled.unallocatedWatts!, cpuEstimate, accuracy: 0.000_001)
    }

    func testDisablingOverlappingEstimateRestoresAttribution() {
        XCTAssertFalse(SMCPowerAccounting.allocation(totalWatts: 20, knownComponents: [18, 4]).canAttributeComponents)
        let gpuOnly = SMCPowerAccounting.allocation(totalWatts: 20, knownComponents: [4])
        XCTAssertTrue(gpuOnly.canAttributeComponents)
        XCTAssertEqual(gpuOnly.unallocatedWatts, 16)
    }

    func testKnownBranchesAndResidualConserveTotal() {
        let components = [3.125, 0.875]
        let result = SMCPowerAccounting.allocation(totalWatts: 21.5, knownComponents: components)
        XCTAssertTrue(result.canAttributeComponents)
        XCTAssertEqual(result.unallocatedWatts, 17.5)
        XCTAssertEqual(components.reduce(0, +) + result.unallocatedWatts!, 21.5)
    }
    func testUnknownComponentsAreNotInvented() {
        XCTAssertEqual(SMCPowerAccounting.allocation(totalWatts: 20, knownComponents: []).unallocatedWatts, 20)
        XCTAssertNil(SMCPowerAccounting.allocation(totalWatts: nil, knownComponents: [2]).unallocatedWatts)
        XCTAssertNil(SMCPowerAccounting.allocation(totalWatts: .nan, knownComponents: [2]).unallocatedWatts)
    }
    func testOverlappingRailsAndInvalidValuesCloseAttribution() {
        let result = SMCPowerAccounting.allocation(totalWatts: 20, knownComponents: [15, 10])
        XCTAssertFalse(result.canAttributeComponents)
        XCTAssertEqual(result.unallocatedWatts, 20)
        XCTAssertFalse(SMCPowerAccounting.allocation(totalWatts: 20, knownComponents: [-1]).canAttributeComponents)
        XCTAssertFalse(SMCPowerAccounting.allocation(totalWatts: 20, knownComponents: [.infinity]).canAttributeComponents)
    }
}
