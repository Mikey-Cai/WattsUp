import Combine
import Foundation
import SwiftUI
import WattsUpCore

enum DashboardTheme: String, CaseIterable, Identifiable {
    case green, blue, purple, amber, rose
    var id: String { rawValue }
    var title: String {
        switch self {
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .amber: return "琥珀"
        case .rose: return "玫瑰"
        }
    }
    var hue: Double {
        switch self {
        case .green: return 0.36
        case .blue: return 0.57
        case .purple: return 0.75
        case .amber: return 0.11
        case .rose: return 0.94
        }
    }
    var tint: Color { Color(hue: hue, saturation: 0.48, brightness: 0.73) }
    var hueShift: Double { hue - DashboardTheme.green.hue }
}

enum FlowDirection: String, CaseIterable, Identifiable {
    case totalOnLeft, totalOnRight
    var id: String { rawValue }
    var title: String { self == .totalOnLeft ? "总量在左" : "总量在右" }
}

enum DashboardCard: String, CaseIterable, Identifiable {
    case memory, power
    var id: String { rawValue }
}

enum DisplayColorRole: String {
    case cpu, gpu, ane, dram, peripheral, unallocated
    case appMemory, wired, compressed, fileCache, free, swap

    var color: Color { color(theme: .green) }

    func color(theme: DashboardTheme) -> Color {
        let palette: (hue: Double, saturation: Double, brightness: Double)
        switch self {
        case .cpu: palette = (0.071, 0.61, 0.95)
        case .gpu: palette = (0.700, 0.41, 0.86)
        case .ane: palette = (0.934, 0.42, 0.91)
        case .dram: palette = (0.500, 0.40, 0.72)
        case .peripheral: palette = (0.578, 0.55, 0.86)
        case .unallocated: return Color(red: 0.63, green: 0.66, blue: 0.70)
        case .appMemory: palette = (0.570, 0.45, 0.84)
        case .wired: palette = (0.773, 0.30, 0.82)
        case .compressed: palette = (0.054, 0.44, 0.90)
        case .fileCache: palette = (0.444, 0.33, 0.73)
        case .free: palette = (0.250, 0.33, 0.78)
        case .swap: palette = (0.768, 0.27, 0.86)
        }
        let shiftedHue = (palette.hue + theme.hueShift + 1).truncatingRemainder(dividingBy: 1)
        return Color(hue: shiftedHue, saturation: palette.saturation, brightness: palette.brightness)
    }
}

enum DisplayPressure {
    case normal, warning, critical, unknown

    var title: String {
        switch self {
        case .normal: return "内存压力 · 正常"
        case .warning: return "内存压力 · 警告"
        case .critical: return "内存压力 · 严重"
        case .unknown: return "内存压力 · 未知"
        }
    }

    var level: MemoryPressureLevel {
        switch self {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return .unknown
        }
    }

    /// Whole-card wash: yellow for warning, red for critical, nothing otherwise.
    var tint: PressureTint { PressureTint(level: level) }

    var color: Color {
        switch self {
        case .normal: return Color(red: 0.35, green: 0.72, blue: 0.48)
        case .warning: return Color(red: 0.91, green: 0.69, blue: 0.22)
        case .critical: return Color(red: 0.89, green: 0.36, blue: 0.38)
        case .unknown: return .secondary
        }
    }
}

struct FlowDisplayItem: Identifiable {
    var id: String
    var title: String
    /// Watts for the power graph, bytes for the memory graph. nil means not plotted.
    var value: Double?
    var role: DisplayColorRole
    var symbol: String
    var isEstimated: Bool
    /// Small second line under the title, e.g. what "其他" contains.
    var caption: String?
    /// Shown instead of a number when value is nil ("本机不可用", "读取中…").
    var statusText: String?
    /// The residual: drawn quieter so it does not read as a measured part.
    var isResidual: Bool
    /// Hover tooltip explaining where the number comes from.
    var helpText: String?

    init(id: String, title: String, value: Double?, role: DisplayColorRole, symbol: String,
         isEstimated: Bool = false, caption: String? = nil, statusText: String? = nil, isResidual: Bool = false,
         helpText: String? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.role = role
        self.symbol = symbol
        self.isEstimated = isEstimated
        self.caption = caption
        self.statusText = statusText
        self.isResidual = isResidual
        self.helpText = helpText
    }

    var displayTitle: String {
        isEstimated && !title.contains("估计") ? title + "（估计）" : title
    }

    var accessibilityTitle: String {
        caption.map { "\(displayTitle)（\($0)）" } ?? displayTitle
    }
}

/// The memory blocks that list their heaviest processes on hover.
enum MemoryHoverTarget: String {
    case physical, app, compressed

    init?(itemID: String) {
        switch itemID {
        case FlowDiagram.sourceHoverID: self = .physical
        case "app": self = .app
        case "compressed": self = .compressed
        default: return nil
        }
    }

    var sort: ProcessMemorySort { self == .compressed ? .compressed : .memory }

    var title: String {
        switch self {
        case .physical: return "占用内存最多的进程"
        case .app: return "App 内存 · 占用最多的进程"
        case .compressed: return "被压缩内存最多的进程"
        }
    }

    var symbol: String {
        switch self {
        case .physical: return "desktopcomputer"
        case .app: return "app.dashed"
        case .compressed: return "arrow.down.right.and.arrow.up.left"
        }
    }
}

struct PowerDisplay {
    /// SMC PSTR.
    var totalWatts: Double?
    /// SMC PP0b, an estimate.
    var cpuEstimateWatts: Double?
    /// IOReport GPU Energy.
    var gpuWatts: Double?
    var gpuPending: Bool = false
    var cpuState: SensorState = .ok
    var gpuState: SensorState = .ok
    /// All-core busy fraction (0…1), shown under the CPU estimate.
    var cpuBusy: Double? = nil
    var note: String?
}

struct MemoryDisplay {
    var totalBytes: Double
    var branches: [FlowDisplayItem]
    /// Swap has no fixed ceiling on macOS, so only the used amount is shown.
    var swapUsedBytes: Double?
    /// 与活动监视器同口径的"已使用内存"= App + 联动 + 压缩
    var usedBytes: Double? = nil
    /// 还能用 = 文件缓存 + 完全空闲(系统随时能把缓存腾出来)
    var availableBytes: Double? = nil
    var pressure: DisplayPressure
    var note: String?
}

struct DashboardSnapshot {
    var timestamp: Date = Date()
    var power: PowerDisplay
    var memory: MemoryDisplay
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var snapshot: DashboardSnapshot?
    @Published var refreshInterval: Double = 2
    @Published var opacity: Double = 0.95
    @Published var isPinned = false
    @Published var isVisible = false
    @Published var errorMessage: String?
    @Published private(set) var theme: DashboardTheme = .green
    @Published private(set) var flowDirection: FlowDirection = .totalOnLeft
    @Published private(set) var cardOrder: [DashboardCard] = [.memory, .power]
    @Published private(set) var enabledPowerComponents: Set<String> = ["cpu", "gpu"]

    private let defaults: UserDefaults
    private let themeKey = "WattsUp.theme.v2"
    private let directionKey = "WattsUp.flowDirection.v2"
    private let cardOrderKey = "WattsUp.cardOrder.v2"
    private let powerComponentsKey = "WattsUp.enabledPowerComponents.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: themeKey), let theme = DashboardTheme(rawValue: raw) {
            self.theme = theme
        }
        if let raw = defaults.string(forKey: directionKey), let direction = FlowDirection(rawValue: raw) {
            flowDirection = direction
        }
        if let raw = defaults.stringArray(forKey: cardOrderKey) {
            let restored = raw.compactMap(DashboardCard.init(rawValue:))
            if restored.count == 2, Set(restored).count == 2 { cardOrder = restored }
        }
        if let restored = defaults.stringArray(forKey: powerComponentsKey) {
            // v0.2 stored "pcie" too; that branch no longer exists.
            enabledPowerComponents = Set(restored).intersection(Self.powerComponentIDs)
        }
    }

    var onRefreshIntervalChange: ((Double) -> Void)?
    var onOpacityChange: ((Double) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    var onRefresh: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?
    /// The header was grabbed to move the window (detaches = pins it).
    var onWindowDragBegan: (() -> Void)?
    /// A card started being dragged to reorder it.
    var onCardDragBegan: (() -> Void)?
    /// Pointer entered (true) or left (false) a memory block.
    var onMemoryHover: ((MemoryHoverTarget, Bool) -> Void)?

    static let powerComponentIDs: Set<String> = ["cpu", "gpu"]

    func setRefreshInterval(_ interval: Double) {
        guard [1.0, 2.0, 5.0].contains(interval) else { return }
        refreshInterval = interval
        onRefreshIntervalChange?(interval)
    }

    func setOpacity(_ value: Double) {
        opacity = min(1, max(0.55, value))
        onOpacityChange?(opacity)
    }

    func setTheme(_ value: DashboardTheme) {
        theme = value
        defaults.set(value.rawValue, forKey: themeKey)
    }

    func setFlowDirection(_ value: FlowDirection) {
        flowDirection = value
        defaults.set(value.rawValue, forKey: directionKey)
    }

    func moveCard(_ card: DashboardCard, before target: DashboardCard) {
        guard card != target, let index = cardOrder.firstIndex(of: target) else { return }
        moveCard(card, to: index)
    }

    func moveCard(_ card: DashboardCard, to index: Int) {
        guard let from = cardOrder.firstIndex(of: card), cardOrder.indices.contains(index), from != index else { return }
        cardOrder.remove(at: from)
        cardOrder.insert(card, at: index)
        defaults.set(cardOrder.map(\.rawValue), forKey: cardOrderKey)
    }

    func setPowerComponent(_ id: String, enabled: Bool) {
        guard Self.powerComponentIDs.contains(id) else { return }
        if enabled { enabledPowerComponents.insert(id) } else { enabledPowerComponents.remove(id) }
        defaults.set(enabledPowerComponents.sorted(), forKey: powerComponentsKey)
    }

    /// Honest split: total from PSTR, GPU from IOReport, CPU as a labelled
    /// estimate, and the rest as "其他". Parts this Mac cannot read at all
    /// (ANE, DRAM, a missing sensor) are left out instead of shown as broken.
    func displayedPowerBranches(_ power: PowerDisplay) -> [FlowDisplayItem] {
        let result = PowerBreakdown.make(
            totalWatts: power.totalWatts, cpuEstimateWatts: power.cpuEstimateWatts, gpuWatts: power.gpuWatts,
            gpuPending: power.gpuPending, cpuState: power.cpuState, gpuState: power.gpuState,
            showCPU: enabledPowerComponents.contains("cpu"), showGPU: enabledPowerComponents.contains("gpu")
        )
        return (result.plotted + result.unplotted).filter { !$0.isHidden }.map { Self.displayItem($0, cpuBusy: power.cpuBusy) }
    }

    static func displayItem(_ branch: PowerBranch, cpuBusy: Double? = nil) -> FlowDisplayItem {
        let text = branch.watts == nil ? branch.statusText : nil
        switch branch.kind {
        case .cpu:
            let busy = cpuBusy.flatMap { $0.isFinite ? "忙碌 \(Int((min(1, max(0, $0)) * 100).rounded()))%" : nil }
            return FlowDisplayItem(id: "cpu", title: "CPU（估计）", value: branch.watts, role: .cpu, symbol: "cpu",
                                   isEstimated: true, caption: busy, statusText: text,
                                   helpText: "来自 SMC 的 PP0b 电源轨：跟着 CPU 负载变化（空闲约 2.5 W，满载多约 10 W），GPU 跑满时它不涨，所以和 GPU 不会重复计算。苹果没有公开它具体管哪些电路，可能还含一点缓存和互联的功耗，所以标「估计」。忙碌度是所有核心的平均占用率。")
        case .gpu:
            return FlowDisplayItem(id: "gpu", title: "GPU", value: branch.watts, role: .gpu,
                                   symbol: "square.stack.3d.up", statusText: text,
                                   helpText: "来自系统能耗计数（IOReport · GPU Energy），和 powermetrics 交叉核对过，量级一致。")
        case .other:
            return FlowDisplayItem(id: "other", title: "其他", value: branch.watts, role: .unallocated,
                                   symbol: "ellipsis.circle", caption: "内存、存储、接口、损耗等",
                                   statusText: text, isResidual: true,
                                   helpText: "整机读数减去上面列出的分项。包括内存、硬盘、接口芯片、电源转换损耗，以及测量误差。这台 Mac 读不到它们各自的功耗，所以合在一起显示。")
        }
    }
}
