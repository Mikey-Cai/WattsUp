import Foundation

/// System memory pressure is a kernel signal, not a percentage of occupied RAM.
public enum MemoryPressureLevel: String, Codable, Sendable, CaseIterable {
    case normal
    case warning
    case critical
    case unknown

    /// The level shown on the panel, judged by what is left ("还能用" = file cache + free) as a share
    /// of physical memory, so it agrees with the numbers beside it. The kernel's own pressure level
    /// tracks compressor and swap work instead and can read "warning" with gigabytes still reclaimable,
    /// which users find contradictory. At least 20% left is normal, at least 8% warning, else critical;
    /// without a breakdown the kernel level is used.
    public static func fromHeadroom(availableBytes: UInt64?, physicalBytes: UInt64?, fallback: Self) -> Self {
        guard let available = availableBytes, let physical = physicalBytes, physical > 0 else { return fallback }
        let fraction = Double(available) / Double(physical)
        if fraction >= 0.20 { return .normal }
        if fraction >= 0.08 { return .warning }
        return .critical
    }

    public static func fromKernelLevel(_ level: Int32) -> Self {
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    /// Dispatch may coalesce flags. The most severe observed event wins.
    public static func fromDispatchFlags(_ flags: UInt) -> Self {
        if flags & 4 != 0 { return .critical }
        if flags & 2 != 0 { return .warning }
        if flags & 1 != 0 { return .normal }
        return .unknown
    }

    public var chineseLabel: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        case .unknown: return "未知"
        }
    }
}

/// A snapshot of page counts, with cumulative counters deliberately excluded.
public struct MemoryPageCounts: Codable, Sendable, Equatable {
    public let free: UInt64
    public let active: UInt64
    public let inactive: UInt64
    public let wired: UInt64
    public let purgeable: UInt64
    public let speculative: UInt64
    public let compressor: UInt64
    public let external: UInt64
    public let `internal`: UInt64
    public let uncompressedInCompressor: UInt64

    public init(
        free: UInt64, active: UInt64 = 0, inactive: UInt64 = 0,
        wired: UInt64, purgeable: UInt64, speculative: UInt64,
        compressor: UInt64, external: UInt64, internal: UInt64,
        uncompressedInCompressor: UInt64 = 0
    ) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.purgeable = purgeable
        self.speculative = speculative
        self.compressor = compressor
        self.external = external
        self.internal = `internal`
        self.uncompressedInCompressor = uncompressedInCompressor
    }
}

/// A conserving physical-memory partition. Swap is intentionally not a member.
public struct MemoryBreakdown: Codable, Sendable, Equatable {
    public let physicalBytes: UInt64
    /// Residual after wired, compressor, cache and free; includes system accounting remainder.
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let freeBytes: UInt64
    /// Anonymous resident pages minus purgeable pages, before physical-total reconciliation.
    public let anonymousAppBytes: UInt64
    /// appBytes minus anonymousAppBytes. Exposed rather than silently hiding OS accounting gaps.
    public let accountingAdjustmentBytes: Int64

    public var memoryUsedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
    public var sumBytes: UInt64 { appBytes + wiredBytes + compressedBytes + cachedBytes + freeBytes }
}

public enum MemoryAccountingError: Error, Equatable, CustomStringConvertible {
    case invalidPageSize
    case invalidPhysicalMemory
    case speculativeExceedsFree
    case purgeableExceedsInternal
    case arithmeticOverflow
    case categoriesExceedPhysicalMemory

    public var description: String {
        switch self {
        case .invalidPageSize: return "运行系统页大小无效"
        case .invalidPhysicalMemory: return "物理内存总量无效"
        case .speculativeExceedsFree: return "推测页数超过包含它的空闲页数"
        case .purgeableExceedsInternal: return "可清除页数超过匿名页数"
        case .arithmeticOverflow: return "内存页数换算溢出"
        case .categoriesExceedPhysicalMemory: return "内存分项超过物理总量，暂不绘制失真的分流"
        }
    }
}

public enum MemoryAccounting {
    public static func calculate(
        raw: MemoryPageCounts, physicalBytes: UInt64, pageSize: UInt64
    ) throws -> MemoryBreakdown {
        guard pageSize > 0 else { throw MemoryAccountingError.invalidPageSize }
        guard physicalBytes > 0, physicalBytes <= UInt64(Int64.max) else {
            throw MemoryAccountingError.invalidPhysicalMemory
        }
        guard raw.speculative <= raw.free else { throw MemoryAccountingError.speculativeExceedsFree }
        guard raw.purgeable <= raw.internal else { throw MemoryAccountingError.purgeableExceedsInternal }

        func bytes(_ pages: UInt64) throws -> UInt64 {
            let (result, overflow) = pages.multipliedReportingOverflow(by: pageSize)
            guard !overflow else { throw MemoryAccountingError.arithmeticOverflow }
            return result
        }
        func sum(_ values: [UInt64]) throws -> UInt64 {
            try values.reduce(0) { partial, value in
                let (result, overflow) = partial.addingReportingOverflow(value)
                guard !overflow else { throw MemoryAccountingError.arithmeticOverflow }
                return result
            }
        }

        // The SDK documents speculative as a subset of free_count. File-backed
        // pages include speculative pages, so subtract them from the free branch.
        let free = try bytes(raw.free - raw.speculative)
        let wired = try bytes(raw.wired)
        // Physical compressor footprint, not total_uncompressed_pages_in_compressor.
        let compressed = try bytes(raw.compressor)
        let cached = try sum([bytes(raw.external), bytes(raw.purgeable)])
        let anonymousApp = try bytes(raw.internal - raw.purgeable)
        let nonApp = try sum([free, wired, compressed, cached])
        guard nonApp <= physicalBytes else { throw MemoryAccountingError.categoriesExceedPhysicalMemory }
        guard anonymousApp <= UInt64(Int64.max) else { throw MemoryAccountingError.arithmeticOverflow }
        let app = physicalBytes - nonApp
        return MemoryBreakdown(
            physicalBytes: physicalBytes,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            freeBytes: free,
            anonymousAppBytes: anonymousApp,
            accountingAdjustmentBytes: Int64(app) - Int64(anonymousApp)
        )
    }
}

public struct MemorySample: Codable, Sendable {
    public let timestamp: Date
    public let physicalBytes: UInt64?
    public let pageSize: UInt64?
    public let breakdown: MemoryBreakdown?
    public let swapUsedBytes: UInt64?
    public let swapTotalBytes: UInt64?
    public let pressure: MemoryPressureLevel
    public let pressureSource: String
    public let pressureTimestamp: Date?
    public let errors: [String]
    public let raw: MemoryPageCounts?

    public init(
        timestamp: Date = Date(), physicalBytes: UInt64?, pageSize: UInt64?,
        breakdown: MemoryBreakdown?, swapUsedBytes: UInt64?, swapTotalBytes: UInt64?,
        pressure: MemoryPressureLevel, pressureSource: String,
        pressureTimestamp: Date? = nil, errors: [String] = [], raw: MemoryPageCounts? = nil
    ) {
        self.timestamp = timestamp
        self.physicalBytes = physicalBytes
        self.pageSize = pageSize
        self.breakdown = breakdown
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
        self.pressureSource = pressureSource
        self.pressureTimestamp = pressureTimestamp
        self.errors = errors
        self.raw = raw
    }
}
