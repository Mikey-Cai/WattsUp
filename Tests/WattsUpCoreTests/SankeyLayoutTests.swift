import XCTest
@testable import WattsUpCore

final class SankeyLayoutTests: XCTestCase {
    func testWidthRatiosAndSourceConservation() {
        let g = SankeyLayout.make(values: [2, 6, 12], height: 240, gap: 12)
        XCTAssertEqual(g.total, 20)
        XCTAssertEqual(g.bands[1].thickness / g.bands[0].thickness, 3, accuracy: 1e-12)
        XCTAssertEqual(g.bands[2].thickness / g.bands[0].thickness, 6, accuracy: 1e-12)
        XCTAssertEqual(g.bands.reduce(0) { $0 + $1.thickness }, g.sourceHeight, accuracy: 1e-10)
        XCTAssertEqual(g.bands[2].sourceY + g.bands[2].thickness, g.sourceTop + g.sourceHeight, accuracy: 1e-10)
        XCTAssertEqual(g.bands[2].targetY + g.bands[2].thickness, g.height, accuracy: 1e-10)
    }

    func testNoFabricatedMinimumWidthOrZeroDestinations() {
        let g = SankeyLayout.make(values: [0, 0.001, 1, -.infinity, -2, .nan], height: 100)
        XCTAssertEqual(g.bands.map(\.index), [1, 2])
        XCTAssertEqual(g.bands[0].thickness / g.bands[1].thickness, 0.001, accuracy: 1e-12)
    }

    func testEmptyAndInvalidGeometryIsFinite() {
        for values: [Double] in [[], [0, 0], [-1, .nan], [.greatestFiniteMagnitude, .greatestFiniteMagnitude]] {
            let g = SankeyLayout.make(values: values, height: 100)
            XCTAssertTrue(g.bands.isEmpty)
            XCTAssertTrue(g.scale.isFinite)
        }
        XCTAssertTrue(SankeyLayout.make(values: [1], height: -.infinity).bands.isEmpty)
    }

    func testTinyCanvasKeepsOrderedNonOverlappingBands() {
        let g = SankeyLayout.make(values: [1, 1, 1], height: 1, gap: 20)
        XCTAssertGreaterThan(g.scale, 0)
        for i in 1..<g.bands.count {
            XCTAssertGreaterThan(g.bands[i].targetY, g.bands[i - 1].targetY + g.bands[i - 1].thickness)
        }
        XCTAssertEqual(g.bands.last!.targetY + g.bands.last!.thickness, 1, accuracy: 1e-12)
    }
}
