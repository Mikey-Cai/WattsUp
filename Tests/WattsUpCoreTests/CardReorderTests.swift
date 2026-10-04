import XCTest
@testable import WattsUpCore

final class CardReorderTests: XCTestCase {
    // Memory card 420 pt on top, power card 300 pt below, 13 pt apart.
    let heights = [420.0, 300.0]

    func testSmallMoveKeepsOrder() {
        let r = CardReorder.step(heights: heights, index: 0, offset: 162, spacing: 13)
        XCTAssertEqual(r.index, 0)
        XCTAssertEqual(r.offset, 162)
    }

    func testCrossingTheNeighboursMiddleSwapsAndKeepsTheCardUnderThePointer() {
        // Bottom edge passes the power card's middle: 13 + 150.
        let r = CardReorder.step(heights: heights, index: 0, offset: 164, spacing: 13)
        XCTAssertEqual(r.index, 1)
        // The layout moves it down by 300 + 13; the drawn offset shrinks by the same amount.
        XCTAssertEqual(r.offset, 164 - 313)
    }

    func testDraggingUpUsesTheCardAboveForTheThreshold() {
        XCTAssertEqual(CardReorder.step(heights: heights, index: 1, offset: -222, spacing: 13).index, 1)
        let r = CardReorder.step(heights: heights, index: 1, offset: -224, spacing: 13)
        XCTAssertEqual(r.index, 0)
        XCTAssertEqual(r.offset, -224 + 433)
    }

    func testNoFlipBackRightAfterASwapWithUnequalHeights() {
        for start in [(0, 164.0), (1, -224.0), (0, 400.0), (1, -600.0)] {
            let first = CardReorder.step(heights: heights, index: start.0, offset: start.1, spacing: 13)
            XCTAssertNotEqual(first.index, start.0)
            // Either swap puts the 300 pt card on top, so the new order is [300, 420].
            let again = CardReorder.step(heights: [300, 420], index: first.index, offset: first.offset, spacing: 13)
            XCTAssertEqual(again.index, first.index, "start \(start)")
            XCTAssertEqual(again.offset, first.offset, "start \(start)")
        }
    }

    func testNoSwapPastTheEnds() {
        XCTAssertEqual(CardReorder.step(heights: heights, index: 1, offset: 900, spacing: 13).index, 1)
        XCTAssertEqual(CardReorder.step(heights: heights, index: 0, offset: -900, spacing: 13).index, 0)
        XCTAssertEqual(CardReorder.step(heights: heights, index: 5, offset: 10, spacing: 13).index, 5)
    }

    func testOneBigMoveCanCrossSeveralCards() {
        let r = CardReorder.step(heights: [100, 100, 100], index: 0, offset: 260, spacing: 10)
        XCTAssertEqual(r.index, 2)
        XCTAssertEqual(r.offset, 260 - 220, accuracy: 1e-9)
    }
}
