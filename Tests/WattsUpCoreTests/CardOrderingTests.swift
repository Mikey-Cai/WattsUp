import XCTest
@testable import WattsUpCore

final class CardOrderingTests: XCTestCase {
    private let all = ["memory", "power", "usage"]

    func testOldSaveGetsTheNewCardAppended() {
        XCTAssertEqual(CardOrdering.restore(saved: ["power", "memory"], all: all), ["power", "memory", "usage"])
        XCTAssertEqual(CardOrdering.restore(saved: nil, all: all), all)
    }

    func testUnknownAndDuplicateIDsAreDropped() {
        XCTAssertEqual(CardOrdering.restore(saved: ["usage", "pcie", "usage", "memory"], all: all), ["usage", "memory", "power"])
    }

    func testMoveAmongAllVisibleCards() {
        XCTAssertEqual(CardOrdering.move("usage", toVisibleIndex: 0, order: all, visible: Set(all)), ["usage", "memory", "power"])
        XCTAssertEqual(CardOrdering.move("memory", toVisibleIndex: 2, order: all, visible: Set(all)), ["power", "usage", "memory"])
    }

    func testHiddenCardKeepsItsSlot() {
        // power is hidden in the middle; swapping the two visible cards leaves it there.
        let moved = CardOrdering.move("usage", toVisibleIndex: 0, order: all, visible: ["memory", "usage"])
        XCTAssertEqual(moved, ["usage", "power", "memory"])
    }

    func testInvalidMovesChangeNothing() {
        XCTAssertEqual(CardOrdering.move("power", toVisibleIndex: 0, order: all, visible: ["memory", "usage"]), all)
        XCTAssertEqual(CardOrdering.move("memory", toVisibleIndex: 5, order: all, visible: Set(all)), all)
        XCTAssertEqual(CardOrdering.move("memory", toVisibleIndex: 0, order: all, visible: Set(all)), all)
    }

    func testTheLastVisibleCardCannotBeHidden() {
        XCTAssertTrue(CardOrdering.canHide("memory", hidden: [], all: all))
        XCTAssertTrue(CardOrdering.canHide("memory", hidden: ["power"], all: all))
        XCTAssertFalse(CardOrdering.canHide("memory", hidden: ["power", "usage"], all: all))
    }
}
