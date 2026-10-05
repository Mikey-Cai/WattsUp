import Foundation

/// The branches WattsUp can talk about on Apple-silicon desktops. On M6 /
/// macOS 27 only the total (SMC PSTR) and GPU (IOReport) are trustworthy; CPU
/// is a correlated SMC rail (PP0b) and is always labelled as an estimate.
/// ANE and DRAM have no readable power here and are not listed at all.
public enum PowerBranchKind: String, Codable, Sendable, CaseIterable {
    case cpu, gpu, other
}

public enum PowerBranchStatus: Equatable, Sendable {
    /// A counter whose meaning is established (GPU energy, the residual).
    case measured
    /// A reading whose electrical boundary is not confirmed (PP0b for CPU).
    case estimated
    /// This Mac never produced a reading for it. The UI hides such branches.
    case unavailable
    /// The counter exists but needs a second sample (IOReport baseline).
    case pending
    /// Read this tick but withheld because it would exceed the measured total.
    case withheld
    /// Worked earlier in this session, but this tick's read failed.
    case failed
    /// Returns the same value tick after tick; not trusted until it moves again.
    case stale
}

public struct PowerBranch: Equatable, Sendable {
    public let kind: PowerBranchKind
    /// Watts drawn in the diagram; nil means "not plotted" (see status).
    public let watts: Double?
    public let status: PowerBranchStatus

    public init(kind: PowerBranchKind, watts: Double?, status: PowerBranchStatus) {
        self.kind = kind
        self.watts = watts
        self.status = status
    }

    /// Chinese UI text for a branch without a plotted value.
    public var statusText: String? {
        switch status {
        case .measured, .estimated: return watts == nil ? "暂无读数" : nil
        case .unavailable: return "本机不可用"
        case .pending: return "读取中…"
        case .withheld: return "本帧超出总功耗"
        case .failed: return "读取失败"
        case .stale: return "数据未更新"
        }
    }

    /// Branches the UI should not show at all (the sensor does not exist here).
    public var isHidden: Bool { status == .unavailable }
}

public struct PowerBreakdownResult: Equatable, Sendable {
    public let totalWatts: Double?
    /// CPU / GPU / other, in display order. Only plotted values sum to the total.
    public let plotted: [PowerBranch]
    /// Branches shown as text below the diagram (pending, withheld, failed, stale).
    public let unplotted: [PowerBranch]

    public var plottedSum: Double { plotted.compactMap(\.watts).reduce(0, +) }
    public func branch(_ kind: PowerBranchKind) -> PowerBranch? {
        (plotted + unplotted).first { $0.kind == kind }
    }
}

public enum PowerBreakdown {
    /// - Parameters:
    ///   - totalWatts: SMC PSTR, the whole-system figure.
    ///   - cpuEstimateWatts: SMC PP0b. Tracks CPU load but its boundary is unconfirmed.
    ///     In the 2026-10-03 calibration it did not rise under a GPU-only load
    ///     (relative to that phase's own idle). Load correlation does not prove
    ///     disjoint electrical boundaries: this is an estimated split.
    ///   - gpuWatts: IOReport "GPU Energy" Δenergy/Δt.
    ///   - gpuPending: the IOReport subscription exists but has no delta yet.
    ///   - cpuState/gpuState: sensor health across ticks (see `SensorHealth`).
    ///     A failed or stale reading is not plotted; its power stays in "other".
    ///   - showCPU/showGPU: user toggles. A hidden branch's power stays in "other".
    public static func make(totalWatts: Double?, cpuEstimateWatts: Double?, gpuWatts: Double?,
                            gpuPending: Bool = false,
                            cpuState: SensorState = .ok, gpuState: SensorState = .ok,
                            showCPU: Bool = true, showGPU: Bool = true) -> PowerBreakdownResult {
        func valid(_ value: Double?, _ state: SensorState) -> Double? {
            guard state == .ok, let value, value.isFinite, value >= 0, value <= 2_000 else { return nil }
            return value
        }
        func missing(_ state: SensorState) -> PowerBranchStatus {
            switch state {
            case .failed: return .failed
            case .stale: return .stale
            case .ok, .absent: return .unavailable
            }
        }
        let total = valid(totalWatts, .ok)
        var gpu = showGPU ? valid(gpuWatts, gpuState) : nil
        var cpu = showCPU ? valid(cpuEstimateWatts, cpuState) : nil
        var unplotted: [PowerBranch] = []

        if let total {
            // Never rescale readings into a fabricated split. A GPU reading that
            // alone exceeds the total is inconsistent this tick; otherwise the
            // less trustworthy CPU estimate gives way first.
            if let g = gpu, g > total + 1e-9 {
                gpu = nil
                unplotted.append(PowerBranch(kind: .gpu, watts: nil, status: .withheld))
            }
            if let c = cpu, c + (gpu ?? 0) > total + 1e-9 {
                cpu = nil
                unplotted.append(PowerBranch(kind: .cpu, watts: nil, status: .withheld))
            }
        }

        var plotted: [PowerBranch] = []
        if showCPU {
            if let cpu { plotted.append(PowerBranch(kind: .cpu, watts: cpu, status: .estimated)) }
            else if !unplotted.contains(where: { $0.kind == .cpu }) {
                unplotted.append(PowerBranch(kind: .cpu, watts: nil, status: missing(cpuState)))
            }
        }
        if showGPU {
            if let gpu { plotted.append(PowerBranch(kind: .gpu, watts: gpu, status: .measured)) }
            else if !unplotted.contains(where: { $0.kind == .gpu }) {
                unplotted.append(PowerBranch(kind: .gpu, watts: nil, status: gpuPending ? .pending : missing(gpuState)))
            }
        }
        let attributed = plotted.compactMap(\.watts).reduce(0, +)
        let other = total.map { max(0, $0 - attributed) }
        plotted.append(PowerBranch(kind: .other, watts: other, status: .measured))
        let order = PowerBranchKind.allCases
        unplotted.sort { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        return PowerBreakdownResult(totalWatts: total, plotted: plotted, unplotted: unplotted)
    }
}
