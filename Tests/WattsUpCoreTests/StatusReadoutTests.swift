import AppKit
import XCTest
@testable import WattsUpCore

final class StatusReadoutTests: XCTestCase {
    private let gb = Units.bytesPerGiB
    private var formatter: StatusReadoutFormatter { .init(physicalBytes: UInt64(24 * gb)) }

    func testPowerAndMemoryPrecisionIncludingRoundingBoundary() {
        for (value, expected) in [(0.0, "0.0"), (-0.0, "0.0"), (0.06, "0.1"), (9.24, "9.2"),
                                   (9.96, "10.0"), (10, "10"), (18.4, "18"), (23.9, "24")] {
            let values = StatusReadoutValues(watts: value, availableBytes: value * gb)
            XCTAssertEqual(formatter.text(for: .power, values: values), expected + " W")
            XCTAssertEqual(formatter.text(for: .memory, values: values), expected + " GB")
        }
    }

    func testPercentUsesWholeNumbersAndRealZero() {
        for (fraction, expected) in [(0.0, "0%"), (0.374, "37%"), (0.999, "100%"), (1, "100%")] {
            let values = StatusReadoutValues(cpuBusy: fraction, gpuBusy: fraction)
            for metric in [StatusReadoutMetric.cpu, .gpu] {
                XCTAssertEqual(formatter.text(for: metric, values: values), expected)
                XCTAssertEqual(formatter.fraction(for: metric, values: values, powerCeiling: 80), fraction)
            }
        }
    }

    func testMissingNonFiniteAndNegativeReadingsAreEmpty() {
        for value: Double? in [nil, .nan, .infinity, -.infinity, -0.1] {
            let values = StatusReadoutValues(watts: value, availableBytes: value, cpuBusy: value, gpuBusy: value)
            for metric in StatusReadoutMetric.allCases {
                XCTAssertEqual(formatter.text(for: metric, values: values), "—")
                XCTAssertNil(formatter.fraction(for: metric, values: values, powerCeiling: 80))
            }
        }
    }

    func testOutOfRangeReadingsAreNotClampedIntoPlausibleNumbers() {
        let values = StatusReadoutValues(watts: 2000.1, availableBytes: 24 * gb + 1, cpuBusy: 1.01, gpuBusy: 1.01)
        for metric in StatusReadoutMetric.allCases {
            XCTAssertEqual(formatter.text(for: metric, values: values), "—")
            XCTAssertNil(formatter.fraction(for: metric, values: values, powerCeiling: 80))
        }
        let unknownPhysical = StatusReadoutFormatter(physicalBytes: 0)
        XCTAssertEqual(unknownPhysical.text(for: .memory, values: .init(availableBytes: 0)), "—")
    }

    func testMemoryNumberIsAvailableButBarIsUsed() {
        let values = StatusReadoutValues(availableBytes: 6 * gb)
        XCTAssertEqual(formatter.text(for: .memory, values: values), "6.0 GB")
        XCTAssertEqual(formatter.fraction(for: .memory, values: values, powerCeiling: 80), 0.75)
        XCTAssertEqual(formatter.fraction(for: .memory, values: .init(availableBytes: 0), powerCeiling: 80), 1)
        XCTAssertEqual(formatter.fraction(for: .memory, values: .init(availableBytes: 24 * gb), powerCeiling: 80), 0)
    }

    func testPowerScaleSaturatesWithoutChangingNumber() {
        XCTAssertEqual(formatter.fraction(for: .power, values: .init(watts: 18), powerCeiling: 80), 0.225)
        XCTAssertEqual(formatter.fraction(for: .power, values: .init(watts: 120), powerCeiling: 80), 1)
        XCTAssertEqual(formatter.text(for: .power, values: .init(watts: 120)), "120 W")
        XCTAssertEqual(formatter.fraction(for: .power, values: .init(watts: 0), powerCeiling: 80), 0)
        for ceiling in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(formatter.fraction(for: .power, values: .init(watts: 18), powerCeiling: ceiling))
        }
    }

    func testDefaultGridOrderAndSelectionSwaps() {
        var settings = StatusReadoutSettings()
        XCTAssertEqual(settings.style, .twoLines)
        XCTAssertEqual(settings.slots, [.memory, .power, .cpu, .gpu])
        XCTAssertEqual(settings.powerCeiling, 80)
        settings.select(.gpu, at: 0)
        XCTAssertEqual(settings.slots, [.gpu, .power, .cpu, .memory])
        settings.select(.gpu, at: 0)
        settings.select(.power, at: -1)
        settings.select(.cpu, at: 4)
        XCTAssertEqual(settings.slots, [.gpu, .power, .cpu, .memory])
    }

    func testPartialOrDuplicateSlotsAreRepairedDeterministically() {
        XCTAssertEqual(StatusReadoutSettings(slots: [.gpu, .gpu, .memory]).slots, [.gpu, .memory, .power, .cpu])
        XCTAssertEqual(StatusReadoutSettings(slots: []).slots, StatusReadoutMetric.allCases)
    }

    func testUserDefaultsRoundTripAndCorruptSettings() throws {
        let suite = "WattsUp.StatusReadoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(StatusReadoutSettings(defaults: defaults), StatusReadoutSettings())
        for style in StatusReadoutStyle.allCases {
            let settings = StatusReadoutSettings(style: style, slots: [.gpu, .cpu, .power, .memory], powerCeiling: 125)
            settings.save(to: defaults)
            XCTAssertEqual(StatusReadoutSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), settings)
        }
        defaults.set("future-style", forKey: StatusReadoutSettings.styleKey)
        defaults.set(["gpu", "unavailable", "gpu"], forKey: StatusReadoutSettings.slotsKey)
        defaults.set(-3, forKey: StatusReadoutSettings.powerCeilingKey)
        let restored = StatusReadoutSettings(defaults: defaults)
        XCTAssertEqual(restored.style, .twoLines)
        XCTAssertEqual(restored.slots, [.gpu, .memory, .power, .cpu])
        XCTAssertEqual(restored.powerCeiling, 80)
    }

    func testPowerCeilingValidation() {
        for invalid in [0.0, 9, -10, 2001, .nan, .infinity] {
            var settings = StatusReadoutSettings(powerCeiling: invalid)
            XCTAssertEqual(settings.powerCeiling, 80)
            settings.setPowerCeiling(160)
            XCTAssertEqual(settings.powerCeiling, 160)
            settings.setPowerCeiling(invalid)
            XCTAssertEqual(settings.powerCeiling, 80)
        }
        for valid in [10.0, 80, 2000] { XCTAssertEqual(StatusReadoutSettings(powerCeiling: valid).powerCeiling, valid) }
    }

    func testSummarySharesPanelHeadroomThresholdsAndFallback() {
        for (available, expected) in [(20.0, "充足"), (19.0, "偏紧"), (8.0, "偏紧"), (7.0, "紧张")] {
            let level = MemoryPressureLevel.fromHeadroom(availableBytes: UInt64(available), physicalBytes: 100, fallback: .unknown)
            let summary = formatter.summary(values: .init(pressure: level), settings: .init())
            XCTAssertTrue(summary.contains("内存\(expected)"))
            XCTAssertTrue(summary.contains("CPU 忙碌%：—"))
            XCTAssertTrue(summary.contains("GPU 忙碌%：—"))
        }
        XCTAssertEqual(MemoryPressureLevel.fromHeadroom(availableBytes: nil, physicalBytes: 100, fallback: .warning), .warning)
        let summary = formatter.summary(values: .init(watts: 18, availableBytes: 9.2 * gb), settings: .init(powerCeiling: 160))
        XCTAssertTrue(summary.contains("9.2 GB"))
        XCTAssertTrue(summary.contains("160 W 满格"))
    }

    @MainActor
    func testWidthReservationsContainEveryFormattedBoundaryAtBothFontSizes() {
        for physicalGB in [8.0, 24, 128, 1536] {
            let formatter = StatusReadoutFormatter(physicalBytes: UInt64(physicalGB * gb))
            for size in [9.5, 11.0] {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)]
                for metric in StatusReadoutMetric.allCases {
                    let reserved = formatter.widthCandidates(for: metric).map { ($0 as NSString).size(withAttributes: attributes).width }.max()!
                    let readings: [StatusReadoutValues] = [
                        .init(), .init(watts: 0, availableBytes: 0, cpuBusy: 0, gpuBusy: 0),
                        .init(watts: 9.99, availableBytes: min(9.99, physicalGB) * gb, cpuBusy: 0.999, gpuBusy: 0.999),
                        .init(watts: 10, availableBytes: min(10, physicalGB) * gb, cpuBusy: 1, gpuBusy: 1),
                        .init(watts: 2000, availableBytes: physicalGB * gb, cpuBusy: 1, gpuBusy: 1)]
                    for values in readings {
                        let text = formatter.text(for: metric, values: values)
                        XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: attributes).width, reserved, text)
                    }
                }
            }
        }
    }

    func testOneCadenceAcrossPanelStatusAndWidgetCombinations() {
        for style in StatusReadoutStyle.allCases {
            let settings = StatusReadoutSettings(style: style)
            for panel in [false, true] {
                for widget in [false, true] {
                    for refresh in [1.0, 2.0, 5.0] {
                        let expected: Double? = panel || style != .iconOnly ? refresh : (widget ? 60 : nil)
                        XCTAssertEqual(SamplingCadence.interval(panelVisible: panel, statusReadout: settings.requiresSampling,
                                                                widgetInstalled: widget, refreshInterval: refresh), expected)
                    }
                    for card in [false, true] {
                        XCTAssertEqual(SamplingCadence.needsUsage(panelVisible: panel, usageCardVisible: card,
                                                                  statusUsage: settings.requiresUsage),
                                       style == .twoLines || (panel && card))
                    }
                }
            }
        }
    }
}
