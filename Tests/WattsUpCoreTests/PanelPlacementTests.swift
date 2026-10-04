import CoreGraphics
import XCTest
@testable import WattsUpCore

final class PanelPlacementTests: XCTestCase {
    // 1920×1080 screen with a 25 pt menu bar.
    let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
    let minimum = CGSize(width: 440, height: 340)

    func testAnchoredUnderIconAndCentred() {
        let icon = CGRect(x: 1500, y: 1056, width: 24, height: 24)
        let frame = PanelPlacement.anchoredFrame(size: CGSize(width: 650, height: 690), anchor: icon,
                                                 visibleFrame: visible, minimum: minimum)
        XCTAssertEqual(frame.midX, icon.midX, accuracy: 1)
        XCTAssertEqual(frame.maxY, icon.minY - 6, accuracy: 1)
        XCTAssertEqual(frame.size, CGSize(width: 650, height: 690))
    }

    func testAnchoredFrameStaysOnScreenNearTheRightEdge() {
        let icon = CGRect(x: 1890, y: 1056, width: 24, height: 24)
        let frame = PanelPlacement.anchoredFrame(size: CGSize(width: 650, height: 690), anchor: icon,
                                                 visibleFrame: visible, minimum: minimum)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 8 + 0.5)
        XCTAssertTrue(visible.contains(frame))
    }

    func testTallRequestIsClampedBelowTheMenuBar() {
        let icon = CGRect(x: 900, y: 1056, width: 24, height: 24)
        let frame = PanelPlacement.anchoredFrame(size: CGSize(width: 650, height: 5_000), anchor: icon,
                                                 visibleFrame: visible, minimum: minimum)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(frame.maxY, icon.minY)
    }

    func testMinimumSizeIsRespected() {
        let size = PanelPlacement.clampedSize(CGSize(width: 10, height: CGFloat.nan), minimum: minimum, visibleFrame: visible)
        XCTAssertEqual(size, minimum)
    }

    func testPinnedFrameOnScreenIsLeftExactlyWhereItIs() {
        let frame = CGRect(x: 123, y: 77, width: 600, height: 500)
        XCTAssertEqual(PanelPlacement.constrained(frame, to: visible), frame)
    }

    func testOffscreenPinnedFrameSlidesBack() {
        let frame = CGRect(x: 1800, y: -200, width: 600, height: 500)
        let fixed = PanelPlacement.constrained(frame, to: visible)
        XCTAssertTrue(visible.contains(fixed))
        XCTAssertEqual(fixed.size, frame.size)
        let huge = PanelPlacement.constrained(CGRect(x: 0, y: 0, width: 4_000, height: 3_000), to: visible)
        XCTAssertEqual(huge, visible)
    }

    func testSavedFrameValidation() {
        XCTAssertNil(PanelPlacement.validSavedFrame(nil, minimum: minimum))
        XCTAssertNil(PanelPlacement.validSavedFrame(CGRect(x: 0, y: 0, width: 100, height: 100), minimum: minimum))
        XCTAssertNil(PanelPlacement.validSavedFrame(CGRect(x: CGFloat.nan, y: 0, width: 600, height: 600), minimum: minimum))
        let ok = CGRect(x: 10, y: 10, width: 600, height: 600)
        XCTAssertEqual(PanelPlacement.validSavedFrame(ok, minimum: minimum), ok)
    }

    func testSideTooltipPrefersTheRoomierSide() {
        let size = CGSize(width: 320, height: 300)
        let rightPanel = CGRect(x: 1200, y: 300, width: 650, height: 690)
        let left = PanelPlacement.sideTooltipFrame(size: size, panel: rightPanel, pointer: CGPoint(x: 1300, y: 600),
                                                   visibleFrame: visible)
        XCTAssertEqual(left.maxX, rightPanel.minX - 8, accuracy: 1)
        XCTAssertEqual(left.midY, 600, accuracy: 1)

        let leftPanel = CGRect(x: 40, y: 300, width: 650, height: 690)
        let right = PanelPlacement.sideTooltipFrame(size: size, panel: leftPanel, pointer: CGPoint(x: 100, y: 600),
                                                    visibleFrame: visible)
        XCTAssertEqual(right.minX, leftPanel.maxX + 8, accuracy: 1)
    }

    func testSideTooltipFallsBackNearThePointerAndStaysOnScreen() {
        let size = CGSize(width: 320, height: 300)
        let wide = CGRect(x: 10, y: 0, width: 1900, height: 1000)
        let frame = PanelPlacement.sideTooltipFrame(size: size, panel: wide, pointer: CGPoint(x: 1800, y: 100),
                                                    visibleFrame: visible)
        XCTAssertTrue(visible.contains(frame))
    }

    // MARK: Resize handles

    func testDraggingRightAndTopEdgesGrowsFromTheFixedCorner() {
        let start = CGRect(x: 100, y: 100, width: 600, height: 500)
        let r = PanelPlacement.resized(start, edges: [.right, .top], delta: CGSize(width: 50, height: 40),
                                       minimum: minimum, bounds: visible)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 650, height: 540))
    }

    func testDraggingLeftAndBottomEdgesKeepsTheOppositeEdgesFixed() {
        let start = CGRect(x: 300, y: 300, width: 600, height: 500)
        let r = PanelPlacement.resized(start, edges: [.left, .bottom], delta: CGSize(width: -80, height: -60),
                                       minimum: minimum, bounds: visible)
        XCTAssertEqual(r.maxX, start.maxX)
        XCTAssertEqual(r.maxY, start.maxY)
        XCTAssertEqual(r.width, 680)
        XCTAssertEqual(r.height, 560)
    }

    func testResizeRespectsMinimumAndScreen() {
        let start = CGRect(x: 300, y: 300, width: 600, height: 500)
        let small = PanelPlacement.resized(start, edges: [.left], delta: CGSize(width: 1_000, height: 0),
                                           minimum: minimum, bounds: visible)
        XCTAssertEqual(small.width, minimum.width)
        XCTAssertEqual(small.maxX, start.maxX, "shrinking from the left never moves the right edge")
        let big = PanelPlacement.resized(start, edges: [.right, .top], delta: CGSize(width: 5_000, height: 5_000),
                                         minimum: minimum, bounds: visible)
        XCTAssertEqual(big.maxX, visible.maxX)
        XCTAssertEqual(big.maxY, visible.maxY)
    }

    func testOnlyTheGrabbedEdgesMove() {
        let start = CGRect(x: 300, y: 300, width: 600, height: 500)
        let r = PanelPlacement.resized(start, edges: [.bottom], delta: CGSize(width: 70, height: -30),
                                       minimum: minimum, bounds: visible)
        XCTAssertEqual(r.minX, start.minX)
        XCTAssertEqual(r.width, start.width, "horizontal motion is ignored for a bottom-edge drag")
        XCTAssertEqual(r.height, 530)
    }

    func testEdgeHitRegions() {
        let size = CGSize(width: 600, height: 500)
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: 2, y: 250), in: size), [.left])
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: 598, y: 250), in: size), [.right])
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: 300, y: 498), in: size), [.top])
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: 300, y: 3), in: size), [.bottom])
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: 10, y: 10), in: size), [.left, .bottom])
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: 590, y: 492), in: size), [.right, .top])
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: 300, y: 250), in: size), [], "the middle is content")
        XCTAssertEqual(PanelPlacement.edges(at: CGPoint(x: -1, y: 250), in: size), [])
    }
}
