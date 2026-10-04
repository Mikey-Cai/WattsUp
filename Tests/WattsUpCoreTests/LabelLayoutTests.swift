import XCTest
@testable import WattsUpCore

final class LabelLayoutTests: XCTestCase {
    func testWellSeparatedLabelsStayOnTheirBands() {
        let ys = LabelLayout.resolve(centers: [20, 80, 140], heights: [28, 28, 28], minY: 0, maxY: 200)
        XCTAssertEqual(ys, [20, 80, 140])
    }

    func testCollidingLabelsArePushedApartInOrder() {
        // 文件缓存 and a thin 空闲 band at the bottom, 22 pt apart.
        let ys = LabelLayout.resolve(centers: [100, 160, 182], heights: [28, 28, 28], spacing: 2, minY: -6, maxY: 196)
        XCTAssertEqual(ys[0], 100)
        XCTAssertGreaterThanOrEqual(ys[2] - ys[1], 30 - 1e-9)
        XCTAssertLessThanOrEqual(ys[2] + 14, 196 + 1e-9)
        XCTAssertTrue(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testTallerCaptionLabelGetsMoreRoom() {
        let ys = LabelLayout.resolve(centers: [50, 60], heights: [28, 39], spacing: 2, minY: 0, maxY: 300)
        XCTAssertGreaterThanOrEqual(ys[1] - ys[0], (28 + 39) / 2 + 2 - 1e-9)
    }

    func testOverflowingStackIsPulledUpButNeverReordered() {
        let ys = LabelLayout.resolve(centers: [10, 12, 14, 16], heights: [28, 28, 28, 28], minY: 0, maxY: 60)
        XCTAssertEqual(ys.count, 4)
        XCTAssertTrue(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(ys[0], 14, "the top label still starts inside the area")
    }

    func testEmptyInput() {
        XCTAssertTrue(LabelLayout.resolve(centers: [], heights: [], minY: 0, maxY: 10).isEmpty)
    }
}
