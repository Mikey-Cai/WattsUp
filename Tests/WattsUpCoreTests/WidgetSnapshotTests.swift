import XCTest
@testable import WattsUpCore

final class WidgetSnapshotTests: XCTestCase {
    let snapshot = WidgetSnapshot(timestamp: Date(timeIntervalSince1970: 1_791_000_000), totalWatts: 16.57,
                                  cpuEstimateWatts: 2.03, gpuWatts: nil,
                                  memoryUsedBytes: 12_884_901_888, memoryTotalBytes: 25_769_803_776,
                                  swapUsedBytes: 0, pressure: "warning")

    func testRoundTripKeepsMissingValuesMissing() throws {
        let data = try snapshot.encoded()
        let decoded = WidgetSnapshot.decode(data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded?.gpuWatts)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("gpuWatts"),
                       "nil readings are omitted, never written as 0")
    }

    func testNewerSchemaIsRejected() throws {
        var future = snapshot
        future.schemaVersion = 99
        XCTAssertNil(WidgetSnapshot.decode(try future.encoded()))
        XCTAssertNil(WidgetSnapshot.decode(Data("not json".utf8)))
    }

    func testDerivedValues() {
        XCTAssertEqual(snapshot.memoryUsedFraction ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(snapshot.pressureTitle, "偏紧")
        var broken = snapshot
        broken.memoryTotalBytes = 0
        XCTAssertNil(broken.memoryUsedFraction)
    }

    func testStaleness() {
        let t = snapshot.timestamp
        XCTAssertFalse(snapshot.isStale(now: t.addingTimeInterval(60)))
        XCTAssertTrue(snapshot.isStale(now: t.addingTimeInterval(11 * 60)))
        XCTAssertTrue(snapshot.isStale(now: t.addingTimeInterval(-600)), "a clock far behind the file is suspicious")
    }

    func testAppGroupComesFromInfoPlistWithATeamPrefix() {
        let key = WidgetSnapshot.appGroupInfoKey
        XCTAssertEqual(WidgetSnapshot.appGroup(fromInfo: [key: "ABCDE12345.io.github.mikey-cai.wattsup"]),
                       "ABCDE12345.io.github.mikey-cai.wattsup")
        // Unfilled placeholder, missing team, wrong suffix or no key: no App Group.
        XCTAssertNil(WidgetSnapshot.appGroup(fromInfo: [key: "__APP_GROUP__"]))
        XCTAssertNil(WidgetSnapshot.appGroup(fromInfo: [key: ".io.github.mikey-cai.wattsup"]))
        XCTAssertNil(WidgetSnapshot.appGroup(fromInfo: [key: "ABCDE12345.example.other"]))
        XCTAssertNil(WidgetSnapshot.appGroup(fromInfo: [key: "$(TEAM).io.github.mikey-cai.wattsup"]))
        XCTAssertNil(WidgetSnapshot.appGroup(fromInfo: [:]))
        XCTAssertNil(WidgetSnapshot.appGroup(fromInfo: nil))
        XCTAssertTrue(WidgetSnapshot.widgetKind.hasPrefix("io.github.mikey-cai.wattsup"))
    }

    func testWritePolicyThrottlesWritesAndReloads() {
        let policy = WidgetWritePolicy(minimumWriteInterval: 15, minimumReloadInterval: 300)
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(policy.shouldWrite(now: t, lastWrite: nil))
        XCTAssertFalse(policy.shouldWrite(now: t.addingTimeInterval(5), lastWrite: t))
        XCTAssertTrue(policy.shouldWrite(now: t.addingTimeInterval(15), lastWrite: t))

        XCTAssertTrue(policy.shouldReload(now: t, lastReload: nil, previousPressure: nil, pressure: "normal"))
        XCTAssertFalse(policy.shouldReload(now: t.addingTimeInterval(60), lastReload: t,
                                           previousPressure: "normal", pressure: "normal"))
        XCTAssertTrue(policy.shouldReload(now: t.addingTimeInterval(60), lastReload: t,
                                          previousPressure: "normal", pressure: "critical"),
                      "a pressure change is shown promptly")
        XCTAssertTrue(policy.shouldReload(now: t.addingTimeInterval(301), lastReload: t,
                                          previousPressure: "normal", pressure: "normal"))
    }
}
