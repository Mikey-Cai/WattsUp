import XCTest
@testable import WattsUpCore

final class PressureTintTests: XCTestCase {
    func testOnlyWarningAndCriticalTint() {
        XCTAssertEqual(PressureTint(level: .normal), .none)
        XCTAssertEqual(PressureTint(level: .unknown), .none)
        XCTAssertEqual(PressureTint(level: .warning), .warning)
        XCTAssertEqual(PressureTint(level: .critical), .critical)
        XCTAssertFalse(PressureTint.none.isTinted)
        XCTAssertTrue(PressureTint.warning.isTinted)
    }

    func testNormalIsCompletelyClear() {
        for dark in [false, true] {
            XCTAssertEqual(PressureTint.none.backgroundOpacity(darkMode: dark), 0)
            XCTAssertEqual(PressureTint.none.trailingOpacity(darkMode: dark), 0)
            XCTAssertEqual(PressureTint.none.borderOpacity(darkMode: dark), 0)
        }
    }

    func testTintIsVisibleButLight() {
        for tint in [PressureTint.warning, .critical] {
            for dark in [false, true] {
                let opacity = tint.backgroundOpacity(darkMode: dark)
                XCTAssertGreaterThan(opacity, 0.05, "\(tint) dark=\(dark) should be noticeable")
                XCTAssertLessThanOrEqual(opacity, 0.2, "\(tint) dark=\(dark) is a reminder, not a fill")
                XCTAssertLessThan(tint.trailingOpacity(darkMode: dark), opacity)
                XCTAssertGreaterThan(tint.borderOpacity(darkMode: dark), 0)
            }
        }
    }

    func testDispatchAndKernelLevelsMapThrough() {
        XCTAssertEqual(PressureTint(level: .fromKernelLevel(2)), .warning)
        XCTAssertEqual(PressureTint(level: .fromKernelLevel(4)), .critical)
        XCTAssertEqual(PressureTint(level: .fromKernelLevel(1)), .none)
        XCTAssertEqual(PressureTint(level: .fromDispatchFlags(2 | 4)), .critical)
    }
}
