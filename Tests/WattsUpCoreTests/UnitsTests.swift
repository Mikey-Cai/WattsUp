import XCTest
@testable import WattsUpCore

final class UnitsTests: XCTestCase {
    func testBinaryMemoryUnits() {
        XCTAssertEqual(Units.gibibytes(25_769_803_776), 24)
        XCTAssertEqual(Units.memory(25_769_803_776), "24.00 GB")
        XCTAssertEqual(Units.memory(524_288_000), "500.0 MB")
        XCTAssertEqual(Units.memory(0), "0 GB")
        XCTAssertEqual(Units.memory(1_073_741_824), "1.00 GB")
    }
    func testUnknownIsNotZero() {
        XCTAssertEqual(Units.watts(nil), "未知")
        XCTAssertEqual(Units.watts(.nan), "未知")
        XCTAssertEqual(Units.memory(-1), "未知")
        XCTAssertEqual(Units.watts(0), "0.00 W")
    }

    func testOptionalByteConversionUsesNumericValue() {
        XCTAssertEqual(Units.scalarBytes(25_769_803_776), 25_769_803_776)
        XCTAssertEqual(Units.scalarBytes(5_368_709_120), 5_368_709_120)
        XCTAssertEqual(Units.scalarBytes(0), 0)
        XCTAssertNil(Units.scalarBytes(nil))
    }
}
