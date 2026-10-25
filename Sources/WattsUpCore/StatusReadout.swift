import Foundation

public enum StatusReadoutStyle: String, CaseIterable, Sendable {
    case twoLines, singleLine, iconOnly

    public var title: String {
        switch self {
        case .twoLines: return "两行四格"
        case .singleLine: return "单行"
        case .iconOnly: return "仅图标"
        }
    }
}

public enum StatusReadoutMetric: String, CaseIterable, Sendable {
    case memory, power, cpu, gpu

    public var title: String {
        switch self {
        case .memory: return "内存余量"
        case .power: return "整机功率"
        case .cpu: return "CPU 忙碌%"
        case .gpu: return "GPU 忙碌%"
        }
    }

    public var shortTitle: String {
        switch self {
        case .memory: return "内存"
        case .power: return "功率"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        }
    }
}

public struct StatusReadoutSettings: Equatable, Sendable {
    public var style: StatusReadoutStyle
    /// Row-major order, always a permutation of the four metrics.
    public private(set) var slots: [StatusReadoutMetric]
    public private(set) var powerCeiling: Double
    public static let styleKey = "WattsUp.statusReadoutStyle.v1"
    public static let slotsKey = "WattsUp.statusReadoutSlots.v1"
    public static let powerCeilingKey = "WattsUp.statusPowerCeiling.v1"
    /// Display scale, not a hardware rating. Local PSTR calibration peaked near 59 W.
    public static let defaultPowerCeiling = 80.0
    public static let powerCeilingRange = 10.0...2_000.0

    public init(style: StatusReadoutStyle = .twoLines, slots: [StatusReadoutMetric] = StatusReadoutMetric.allCases,
                powerCeiling: Double = defaultPowerCeiling) {
        self.style = style
        var unique: [StatusReadoutMetric] = []
        for metric in slots + StatusReadoutMetric.allCases where !unique.contains(metric) { unique.append(metric) }
        self.slots = unique
        self.powerCeiling = Self.validCeiling(powerCeiling)
    }

    public init(defaults: UserDefaults) {
        self.init(style: defaults.string(forKey: Self.styleKey).flatMap(StatusReadoutStyle.init(rawValue:)) ?? .twoLines,
                  slots: (defaults.stringArray(forKey: Self.slotsKey) ?? []).compactMap(StatusReadoutMetric.init(rawValue:)),
                  powerCeiling: defaults.object(forKey: Self.powerCeilingKey) == nil
                    ? Self.defaultPowerCeiling : defaults.double(forKey: Self.powerCeilingKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(style.rawValue, forKey: Self.styleKey)
        defaults.set(slots.map(\.rawValue), forKey: Self.slotsKey)
        defaults.set(powerCeiling, forKey: Self.powerCeilingKey)
    }

    /// Selecting an occupied metric swaps the two cells, keeping all four useful.
    public mutating func select(_ metric: StatusReadoutMetric, at index: Int) {
        guard slots.indices.contains(index), let other = slots.firstIndex(of: metric) else { return }
        slots.swapAt(index, other)
    }

    public mutating func setPowerCeiling(_ value: Double) { powerCeiling = Self.validCeiling(value) }

    private static func validCeiling(_ value: Double) -> Double {
        value.isFinite && powerCeilingRange.contains(value) ? value : defaultPowerCeiling
    }

    public var requiresSampling: Bool { style != .iconOnly }
    public var requiresUsage: Bool { style == .twoLines }
}

/// Values already collected for the dashboard; no sensor reads or timers here.
public struct StatusReadoutValues: Equatable, Sendable {
    public var watts: Double?
    public var availableBytes: Double?
    public var cpuBusy: Double?
    public var gpuBusy: Double?
    /// The panel's shared fromHeadroom result, including its kernel fallback.
    public var pressure: MemoryPressureLevel

    public init(watts: Double? = nil, availableBytes: Double? = nil, cpuBusy: Double? = nil,
                gpuBusy: Double? = nil, pressure: MemoryPressureLevel = .unknown) {
        self.watts = watts
        self.availableBytes = availableBytes
        self.cpuBusy = cpuBusy
        self.gpuBusy = gpuBusy
        self.pressure = pressure
    }
}

public struct StatusReadoutFormatter: Sendable {
    public let physicalBytes: UInt64
    private let locale = Locale(identifier: "en_US_POSIX")

    public init(physicalBytes: UInt64) { self.physicalBytes = physicalBytes }

    public func text(for metric: StatusReadoutMetric, values: StatusReadoutValues) -> String {
        guard let value = validatedValue(for: metric, values: values) else { return "—" }
        switch metric {
        case .power: return compact(value, unit: "W")
        case .memory: return compact(value / Units.bytesPerGiB, unit: "GB")
        case .cpu, .gpu: return String(format: "%.0f%%", locale: locale, value * 100)
        }
    }

    /// nil is an empty track; a real zero remains a valid, empty reading.
    public func fraction(for metric: StatusReadoutMetric, values: StatusReadoutValues, powerCeiling: Double) -> Double? {
        guard let value = validatedValue(for: metric, values: values) else { return nil }
        switch metric {
        case .memory: return 1 - value / Double(physicalBytes)
        case .power:
            guard powerCeiling.isFinite, powerCeiling > 0 else { return nil }
            return min(1, value / powerCeiling)
        case .cpu, .gpu: return value
        }
    }

    private func validatedValue(for metric: StatusReadoutMetric, values: StatusReadoutValues) -> Double? {
        switch metric {
        case .power: return SMCPowerAccounting.sensorWatts(type: "flt ", value: values.watts)
        case .memory:
            guard let value = values.availableBytes, value.isFinite, value >= 0,
                  physicalBytes > 0, value <= Double(physicalBytes) else { return nil }
            return value
        case .cpu, .gpu:
            guard let value = metric == .cpu ? values.cpuBusy : values.gpuBusy,
                  value.isFinite, (0...1).contains(value) else { return nil }
            return value
        }
    }

    private func compact(_ value: Double, unit: String) -> String {
        String(format: value < 10 ? "%.1f %@" : "%.0f %@", locale: locale, value == 0 ? 0 : value, unit)
    }

    /// Measure once in the actual monospaced-digit font, never from a sample.
    /// All integer places use the same width; keep a separate decimal candidate.
    public func widthCandidates(for metric: StatusReadoutMetric) -> [String] {
        switch metric {
        case .power: return ["—", "10.0 W", "8888 W"] // validated sensor ceiling: 2000 W
        case .memory:
            let maximum = compact(Double(physicalBytes) / Units.bytesPerGiB, unit: "GB")
            return ["—", "10.0 GB", String(maximum.map { $0.isNumber ? "8" : $0 })]
        case .cpu, .gpu: return ["—", "100%"]
        }
    }

    public func summary(values: StatusReadoutValues, settings: StatusReadoutSettings) -> String {
        if settings.style == .iconOnly {
            return "WattsUp：功耗与内存 · 左键打开面板；右键打开菜单"
        }
        let metrics: [StatusReadoutMetric] = settings.style == .twoLines ? settings.slots : [.power, .memory]
        let readings = metrics.map { "\($0.title)：\(text(for: $0, values: values))" }
        let level: String
        switch values.pressure {
        case .normal: level = "充足"
        case .warning: level = "偏紧"
        case .critical: level = "紧张"
        case .unknown: level = "未知"
        }
        return (["WattsUp"] + readings + ["内存\(level)",
            "内存条：已用 / 物理内存；数值：还能用（缓存 + 空闲）",
            "功率条：\(compact(settings.powerCeiling, unit: "W")) 满格；PSTR 系统读数",
            "左键打开面板；右键打开菜单"]).joined(separator: " · ")
    }
}

/// One shared sampling clock. Numeric readouts keep the user-selected cadence
/// with the panel closed; icon-only retains the existing widget/idle policy.
public enum SamplingCadence {
    public static func interval(panelVisible: Bool, statusReadout: Bool, widgetInstalled: Bool,
                                refreshInterval: Double) -> Double? {
        if panelVisible || statusReadout { return refreshInterval }
        return widgetInstalled ? 60 : nil
    }

    public static func needsUsage(panelVisible: Bool, usageCardVisible: Bool, statusUsage: Bool) -> Bool {
        (panelVisible && usageCardVisible) || statusUsage
    }
}
