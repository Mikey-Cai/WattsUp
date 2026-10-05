import XCTest
@testable import WattsUpCore

final class SensorHealthTests: XCTestCase {
    func testNeverValidIsAbsentAndLaterFailureIsFailed() {
        var h = SensorHealth()
        XCTAssertEqual(h.observe(nil, at: 0), .absent)
        XCTAssertEqual(h.observe(.nan, at: 1), .absent)
        XCTAssertEqual(h.observe(2.5, at: 2), .ok)
        XCTAssertEqual(h.observe(nil, at: 3), .failed)
        XCTAssertEqual(h.observe(-1, at: 4), .failed)
        XCTAssertEqual(h.observe(2.6, at: 5), .ok)
    }

    func testSameValueBecomesStaleOnlyAfterTimeAndRepeats() {
        var h = SensorHealth(staleSeconds: 10, minRepeats: 3)
        XCTAssertEqual(h.observe(3.25, at: 0), .ok)
        XCTAssertEqual(h.observe(3.25, at: 1), .ok)
        XCTAssertEqual(h.observe(3.25, at: 2), .ok, "three quick repeats are not enough")
        XCTAssertEqual(h.observe(3.25, at: 10), .stale)
        XCTAssertEqual(h.observe(3.30, at: 11), .ok, "moving again clears it")
    }

    func testTwoSlowSamplesAreNotStale() {
        // Background widget ticks are 60 s apart; two equal samples are not proof.
        var h = SensorHealth(staleSeconds: 10, minRepeats: 3)
        XCTAssertEqual(h.observe(7, at: 0), .ok)
        XCTAssertEqual(h.observe(7, at: 60), .ok)
        XCTAssertEqual(h.observe(7, at: 120), .stale)
    }

    func testDefaultsTolerateTheSMCRefreshInterval() {
        // PP0b repeated the identical float for 2–3 s in the 2026-10-03
        // calibration; at a 1 s refresh that must not read as a frozen sensor.
        var h = SensorHealth()
        for t in 0..<30 { XCTAssertEqual(h.observe(6.471349239349365, at: Double(t)), .ok, "t=\(t)") }
        XCTAssertEqual(h.observe(6.471349239349365, at: 30), .stale, "30 s without any change is not a refresh gap")
    }

    func testStaleDetectionCanBeTurnedOffForIdleZeroCounters() {
        // A power-gated GPU reads 0 W tick after tick; that is not a frozen counter.
        var h = SensorHealth(staleSeconds: 4, minRepeats: 3)
        for t in 0..<20 { XCTAssertEqual(h.observe(0, at: Double(t), detectStale: false), .ok) }
        XCTAssertEqual(h.observe(nil, at: 20, detectStale: false), .failed)
    }

    func testFailureResetsTheRepeatRun() {
        var h = SensorHealth(staleSeconds: 2, minRepeats: 3)
        _ = h.observe(1, at: 0)
        _ = h.observe(1, at: 1)
        XCTAssertEqual(h.observe(nil, at: 2), .failed)
        XCTAssertEqual(h.observe(1, at: 3), .ok)
        XCTAssertEqual(h.observe(1, at: 4), .ok)
        XCTAssertEqual(h.observe(1, at: 5), .stale)
    }
}
