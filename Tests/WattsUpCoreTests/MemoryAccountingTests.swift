import Foundation
import XCTest
@testable import WattsUpCore

final class MemoryAccountingTests: XCTestCase {
    // 100 physical pages: free 15 (including 5 speculative), wired 20,
    // compressor 10, external 25 (including those speculative), internal 35.
    private let raw = MemoryPageCounts(
        free: 15, wired: 20, purgeable: 5, speculative: 5,
        compressor: 10, external: 25, internal: 35,
        uncompressedInCompressor: 90
    )

    func testPhysicalPartitionConservesAndDoesNotDoubleCountPurgeable() throws {
        let result = try MemoryAccounting.calculate(raw: raw, physicalBytes: 100 * 16_384, pageSize: 16_384)
        XCTAssertEqual(result.appBytes, 30 * 16_384)
        XCTAssertEqual(result.anonymousAppBytes, result.appBytes)
        XCTAssertEqual(result.cachedBytes, 30 * 16_384)
        XCTAssertEqual(result.sumBytes, result.physicalBytes)
        XCTAssertEqual(result.accountingAdjustmentBytes, 0)
    }

    func testSpeculativePagesAreExcludedFromFreeRatherThanCountedTwice() throws {
        let result = try MemoryAccounting.calculate(raw: raw, physicalBytes: 100 * 4_096, pageSize: 4_096)
        XCTAssertEqual(result.freeBytes, 10 * 4_096)
        XCTAssertEqual(result.sumBytes, 100 * 4_096)
    }

    func testCompressedBranchUsesPhysicalCompressorPages() throws {
        let result = try MemoryAccounting.calculate(raw: raw, physicalBytes: 100 * 4_096, pageSize: 4_096)
        XCTAssertEqual(result.compressedBytes, 10 * 4_096)
        XCTAssertNotEqual(result.compressedBytes, raw.uncompressedInCompressor * 4_096)
    }

    func testSystemAccountingRemainderIsExplicitAndConserving() throws {
        let result = try MemoryAccounting.calculate(raw: raw, physicalBytes: 105 * 4_096, pageSize: 4_096)
        XCTAssertEqual(result.appBytes, 35 * 4_096)
        XCTAssertEqual(result.anonymousAppBytes, 30 * 4_096)
        XCTAssertEqual(result.accountingAdjustmentBytes, 5 * 4_096)
        XCTAssertEqual(result.sumBytes, result.physicalBytes)
    }

    func testSwapIsOutsidePhysicalPartition() throws {
        let result = try MemoryAccounting.calculate(raw: raw, physicalBytes: 100 * 4_096, pageSize: 4_096)
        let sample = MemorySample(physicalBytes: result.physicalBytes, pageSize: 4_096,
            breakdown: result, swapUsedBytes: 5_000_000_000, swapTotalBytes: 8_000_000_000,
            pressure: .normal, pressureSource: "test", raw: raw)
        XCTAssertEqual(sample.breakdown?.sumBytes, 100 * 4_096)
        XCTAssertEqual(sample.swapUsedBytes, 5_000_000_000)
    }

    func testKernelPressureMappingDoesNotTreatUnknownAsGreen() {
        XCTAssertEqual(MemoryPressureLevel.fromKernelLevel(1), .normal)
        XCTAssertEqual(MemoryPressureLevel.fromKernelLevel(2), .warning)
        XCTAssertEqual(MemoryPressureLevel.fromKernelLevel(4), .critical)
        for value: Int32 in [-1, 0, 3, 5, 8] {
            XCTAssertEqual(MemoryPressureLevel.fromKernelLevel(value), .unknown)
        }
    }

    func testCoalescedDispatchPressureUsesMostSevereFlag() {
        XCTAssertEqual(MemoryPressureLevel.fromDispatchFlags(1), .normal)
        XCTAssertEqual(MemoryPressureLevel.fromDispatchFlags(3), .warning)
        XCTAssertEqual(MemoryPressureLevel.fromDispatchFlags(7), .critical)
        XCTAssertEqual(MemoryPressureLevel.fromDispatchFlags(0), .unknown)
        XCTAssertEqual(MemoryPressureLevel.fromDispatchFlags(8), .unknown)
    }

    func testInvalidCountsDoNotProduceNegativeOrScaledFakeBranches() {
        XCTAssertThrowsError(try MemoryAccounting.calculate(raw: raw, physicalBytes: 100, pageSize: 0)) {
            XCTAssertEqual($0 as? MemoryAccountingError, .invalidPageSize)
        }
        XCTAssertThrowsError(try MemoryAccounting.calculate(raw: raw, physicalBytes: 0, pageSize: 4_096)) {
            XCTAssertEqual($0 as? MemoryAccountingError, .invalidPhysicalMemory)
        }
        let badFree = MemoryPageCounts(free: 2, wired: 1, purgeable: 0, speculative: 3, compressor: 0, external: 0, internal: 1)
        XCTAssertThrowsError(try MemoryAccounting.calculate(raw: badFree, physicalBytes: 100, pageSize: 1)) {
            XCTAssertEqual($0 as? MemoryAccountingError, .speculativeExceedsFree)
        }
        let badPurgeable = MemoryPageCounts(free: 2, wired: 1, purgeable: 3, speculative: 0, compressor: 0, external: 0, internal: 1)
        XCTAssertThrowsError(try MemoryAccounting.calculate(raw: badPurgeable, physicalBytes: 100, pageSize: 1)) {
            XCTAssertEqual($0 as? MemoryAccountingError, .purgeableExceedsInternal)
        }
        XCTAssertThrowsError(try MemoryAccounting.calculate(raw: raw, physicalBytes: 50, pageSize: 1)) {
            XCTAssertEqual($0 as? MemoryAccountingError, .categoriesExceedPhysicalMemory)
        }
    }

    func testArithmeticOverflowIsRejected() {
        let huge = MemoryPageCounts(free: 0, wired: UInt64.max, purgeable: 0, speculative: 0, compressor: 0, external: 0, internal: 0)
        XCTAssertThrowsError(try MemoryAccounting.calculate(raw: huge, physicalBytes: 100, pageSize: 16_384)) {
            XCTAssertEqual($0 as? MemoryAccountingError, .arithmeticOverflow)
        }
    }

    func testSamplesPreserveUnavailableSwapAndUnknownPressureInJSON() throws {
        let sample = MemorySample(physicalBytes: nil, pageSize: nil, breakdown: nil,
            swapUsedBytes: nil, swapTotalBytes: nil, pressure: .unknown,
            pressureSource: "unavailable", errors: ["vm.swapusage: Operation not permitted"])
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(MemorySample.self, from: data)
        XCTAssertNil(decoded.swapUsedBytes)
        XCTAssertEqual(decoded.pressure, .unknown)
        XCTAssertEqual(decoded.errors, sample.errors)
    }

    func testHeadroomLevelFollowsWhatIsLeft() {
        let gb: UInt64 = 1_073_741_824
        // 10/5: kernel said warning while 6.73 of 24 GB was still reclaimable; the panel now says normal.
        XCTAssertEqual(MemoryPressureLevel.fromHeadroom(availableBytes: 6_730_000_000, physicalBytes: 24 * gb, fallback: .warning), .normal)
        XCTAssertEqual(MemoryPressureLevel.fromHeadroom(availableBytes: 3 * gb, physicalBytes: 24 * gb, fallback: .normal), .warning)
        XCTAssertEqual(MemoryPressureLevel.fromHeadroom(availableBytes: gb, physicalBytes: 24 * gb, fallback: .normal), .critical)
        XCTAssertEqual(MemoryPressureLevel.fromHeadroom(availableBytes: nil, physicalBytes: 24 * gb, fallback: .warning), .warning)
        XCTAssertEqual(MemoryPressureLevel.fromHeadroom(availableBytes: gb, physicalBytes: 0, fallback: .unknown), .unknown)
    }
}
