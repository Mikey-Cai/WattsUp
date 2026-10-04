import AppKit
import SwiftUI
import WattsUpCore

let readingAnimation = Animation.easeInOut(duration: 0.4)

enum FlowDisplayUnit {
    case power, memory, bandwidth

    func format(_ value: Double?) -> String {
        switch self {
        case .power: return Units.watts(value)
        case .memory: return Units.memory(value)
        case .bandwidth:
            guard let value, value.isFinite, value >= 0 else { return "暂无读数" }
            return String(format: value < 100 ? "%.1f GB/s" : "%.0f GB/s", value)
        }
    }
}

/// Text is rebuilt from the interpolated value on every animation frame.
/// The caller's existing rounded/monospaced number font is inherited unchanged.
struct AnimatedReadingText: View {
    var value: Double?
    var unit: FlowDisplayUnit

    var body: some View {
        Group {
            if let value, value.isFinite, value >= 0 {
                InterpolatedReadingText(value: value, unit: unit)
                    .animation(readingAnimation, value: value)
            } else {
                Text("暂无读数")
            }
        }
    }
}

private struct InterpolatedReadingText: View, Animatable {
    var value: Double
    var unit: FlowDisplayUnit
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(unit.format(max(0, value))) }
}

/// Single-source, proportional Sankey. Each ribbon and node interpolates its
/// actual coordinates and thickness; this is not a crossfade of two canvases.
struct FlowDiagram: View {
    var sourceTitle: String
    var sourceSymbol: String
    var total: Double?
    var items: [FlowDisplayItem]
    var unit: FlowDisplayUnit
    var height: Double
    var gap: Double
    /// Off when the card already shows this number in its headline, so the
    /// same reading is not printed twice.
    var showsSourceValue = true
    var theme: DashboardTheme = .green
    var direction: FlowDirection = .totalOnLeft
    /// Item ids (and `sourceHoverID` for the total) that report pointer hover.
    var hoverTargets: Set<String> = []
    var onHover: ((String, Bool) -> Void)? = nil

    static let sourceHoverID = "__source"
    @State private var hoveredID: String?

    private var plottedItems: [FlowDisplayItem] {
        items.filter { item in
            guard let value = item.value else { return false }
            return value.isFinite && value >= 0
        }
    }

    private var unplottedItems: [FlowDisplayItem] {
        items.filter { item in
            guard let value = item.value else { return true }
            return !value.isFinite || value < 0
        }
    }

    private var actualHeight: Double { max(height, Double(max(1, plottedItems.count)) * 30) }
    private var isMirrored: Bool { direction == .totalOnRight }

    var body: some View {
        VStack(alignment: isMirrored ? .leading : .trailing, spacing: 7) {
            GeometryReader { proxy in
                let width = Double(proxy.size.width)
                let values = plottedItems.map { $0.value ?? 0 }
                let gapCount = max(0, values.count - 1)
                let actualGap = gapCount > 0 ? min(gap, actualHeight * 0.4 / Double(gapCount)) : 0
                let zeroCount = values.filter { $0 == 0 }.count
                // Keep zero-valued destinations in place. Reserve their row gaps
                // before asking the core for the exact proportional scale.
                let geometry = SankeyLayout.make(
                    values: values, height: actualHeight - Double(zeroCount) * actualGap, gap: actualGap
                )
                let leftSourceX = 109.0
                let leftTargetX = max(leftSourceX + 45, width - 133)
                let sourceX = isMirrored ? width - leftSourceX : leftSourceX
                let targetX = isMirrored ? width - leftTargetX : leftTargetX
                let sourceIsKnown = total?.isFinite == true && (total ?? 0) >= 0
                let conserves = sourceIsKnown && geometry.total > 0
                    && abs((total ?? 0) - geometry.total) <= max(0.001, (total ?? 0) * 0.000001)
                let entries = stableEntries(scale: geometry.scale, gap: actualGap,
                                            sourceTop: geometry.sourceTop + Double(zeroCount) * actualGap / 2)
                // Thin neighbouring bands would make their labels collide; nudge
                // labels apart while keeping each as close to its band as possible.
                let labelYs = LabelLayout.resolve(
                    centers: entries.map { $0.targetY + $0.thickness / 2 },
                    heights: entries.map { $0.item.caption == nil ? 28 : 39 },
                    spacing: 2, minY: -6, maxY: actualHeight + 6)
                let labelY = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), labelYs))
                let animatedGeometry = entries.flatMap { [$0.sourceY, $0.targetY, $0.thickness] } + labelYs
                ZStack(alignment: .topLeading) {
                    if !conserves {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.035))
                            .overlay {
                                Text(!sourceIsKnown ? "来源读数暂不可用" : (total == 0 ? "当前没有流量" : "分项暂不能组成流向"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: max(36, abs(targetX - sourceX) - 9), height: 55)
                            .position(x: (sourceX + targetX) / 2, y: actualHeight / 2)
                    }

                    ForEach(entries) { entry in
                        let color = entry.item.role.color(theme: theme)
                        // The residual is "whatever is left", not a measured part:
                        // draw it as a soft neutral wash so it does not dominate.
                        let ribbonStart = entry.item.isResidual ? 0.16 : 0.40
                        let ribbonEnd = entry.item.isResidual ? 0.30 : 0.80
                        let nodeOpacity = entry.item.isResidual ? 0.45 : 0.95
                        if conserves || (sourceIsKnown && total == 0) {
                            RibbonShape(sourceX: sourceX, targetX: targetX,
                                        sourceY: entry.sourceY, targetY: entry.targetY, thickness: entry.thickness)
                                .fill(LinearGradient(colors: [color.opacity(ribbonStart), color.opacity(ribbonEnd)],
                                                     startPoint: isMirrored ? .trailing : .leading,
                                                     endPoint: isMirrored ? .leading : .trailing))
                                .accessibilityHidden(true)
                            BandNodeShape(x: sourceX + (isMirrored ? 0 : -7), y: entry.sourceY, thickness: entry.thickness)
                                .fill(color.opacity(nodeOpacity))
                                .accessibilityHidden(true)
                            BandNodeShape(x: targetX + (isMirrored ? -7 : 0), y: entry.targetY, thickness: entry.thickness)
                                .fill(color.opacity(nodeOpacity))
                                .accessibilityHidden(true)
                        }
                        destinationLabel(entry.item)
                            .frame(width: 121, alignment: isMirrored ? .trailing : .leading)
                            .contentShape(Rectangle())
                            .optionalHelp(entry.item.helpText)
                            .hoverable(id: entry.item.id, targets: hoverTargets, hoveredID: $hoveredID, onHover: onHover)
                            .position(x: targetX + (isMirrored ? -72.5 : 72.5),
                                      y: labelY[entry.id] ?? entry.targetY + entry.thickness / 2)
                    }
                    sourceLabel
                        .frame(width: 91)
                        .hoverable(id: Self.sourceHoverID, targets: hoverTargets, hoveredID: $hoveredID, onHover: onHover)
                        .position(x: isMirrored ? width - 45.5 : 45.5, y: actualHeight / 2)
                }
                .animation(readingAnimation, value: animatedGeometry)
            }
            .frame(height: actualHeight)

            if !unplottedItems.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 5) {
                    ForEach(unplottedItems) { item in
                        HStack(spacing: 4) {
                            Circle().fill(item.role.color(theme: theme).opacity(item.statusText == nil ? 1 : 0.45))
                                .frame(width: 5, height: 5)
                            Text(item.displayTitle).font(.system(size: 9.5))
                            if let status = item.statusText {
                                Text(status).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            } else {
                                AnimatedReadingText(value: item.value, unit: unit)
                                    .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .optionalHelp(item.helpText)
                    }
                }
                .padding(isMirrored ? .trailing : .leading, 98)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private func stableEntries(scale: Double, gap: Double, sourceTop: Double) -> [FlowBandEntry] {
        var accumulated = 0.0
        let targetTop = scale > 0 ? 0 : max(0, (actualHeight - Double(max(0, plottedItems.count - 1)) * gap) / 2)
        return plottedItems.enumerated().map { index, item in
            let thickness = max(0, item.value ?? 0) * scale
            let entry = FlowBandEntry(item: item, sourceY: sourceTop + accumulated,
                                      targetY: targetTop + accumulated + Double(index) * gap, thickness: thickness)
            accumulated += thickness
            return entry
        }
    }

    private var sourceLabel: some View {
        VStack(spacing: 5) {
            Image(systemName: sourceSymbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.tint)
            Text(sourceTitle).font(.system(size: 10, weight: .medium))
            if showsSourceValue {
                AnimatedReadingText(value: total, unit: unit)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.70)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(theme.tint.opacity(0.085), in: RoundedRectangle(cornerRadius: 14))
    }

    private func destinationLabel(_ item: FlowDisplayItem) -> some View {
        HStack(alignment: .center, spacing: 5) {
            if !isMirrored { destinationIcon(item) }
            VStack(alignment: isMirrored ? .trailing : .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let caption = item.caption {
                    Text(caption)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                AnimatedReadingText(value: item.value, unit: unit)
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isMirrored { destinationIcon(item) }
        }
    }

    private func destinationIcon(_ item: FlowDisplayItem) -> some View {
        Image(systemName: item.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(item.role.color(theme: theme))
            .frame(width: 15)
    }

    private var accessibilityDescription: String {
        "\(sourceTitle) \(unit.format(total))；" + items.map {
            "\($0.accessibilityTitle) \($0.statusText ?? unit.format($0.value))"
        }.joined(separator: "；")
    }
}

private struct FlowBandEntry: Identifiable {
    var item: FlowDisplayItem
    var sourceY: Double
    var targetY: Double
    var thickness: Double
    var id: String { item.id }
}

private struct RibbonShape: Shape {
    var sourceX: Double
    var targetX: Double
    var sourceY: Double
    var targetY: Double
    var thickness: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(sourceY, targetY), thickness) }
        set {
            sourceY = newValue.first.first
            targetY = newValue.first.second
            thickness = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let bend = (targetX - sourceX) * 0.48
        var path = Path()
        path.move(to: CGPoint(x: sourceX, y: sourceY))
        path.addCurve(to: CGPoint(x: targetX, y: targetY),
                      control1: CGPoint(x: sourceX + bend, y: sourceY),
                      control2: CGPoint(x: targetX - bend, y: targetY))
        path.addLine(to: CGPoint(x: targetX, y: targetY + thickness))
        path.addCurve(to: CGPoint(x: sourceX, y: sourceY + thickness),
                      control1: CGPoint(x: targetX - bend, y: targetY + thickness),
                      control2: CGPoint(x: sourceX + bend, y: sourceY + thickness))
        path.closeSubpath()
        return path
    }
}

private struct BandNodeShape: Shape {
    var x: Double
    var y: Double
    var thickness: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(y, thickness) }
        set { y = newValue.first; thickness = newValue.second }
    }
    func path(in rect: CGRect) -> Path { Path(CGRect(x: x, y: y, width: 7, height: max(0, thickness))) }
}

/// Swap on macOS has no fixed ceiling — the system grows swap files on demand —
/// so only the amount in use is shown (no "of N GB", no proportion bar).
/// DRAM read+write speed, shown only on Macs that expose the PMP histogram.
struct MemoryBandwidthView: View {
    var reading: MemoryBandwidthReading
    var theme: DashboardTheme = .green

    var body: some View {
        HStack(spacing: 5) {
            Label("内存读写", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 10.5, weight: .medium))
            Text(reading.atCeiling ? "到了计数上限" : "所有部件合计").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if !reading.atCeiling { Text("约").foregroundStyle(.secondary) }
            AnimatedReadingText(value: reading.gigabytesPerSecond, unit: .bandwidth)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if reading.atCeiling { Text("以上").foregroundStyle(.secondary) }
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(theme.tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .help("内存控制器统计的读写速度（IOReport · PMP）：按速度分档记下的次数推算出平均值，实测误差约一成。计数最高一档是 128 GB/s，超过时只能显示「128 GB/s 以上」。机型的理论上限通常更高，但 CPU 单独跑一般只能用到七八成。")
    }
}

struct SwapUsageView: View {
    var usedBytes: Double?
    var theme: DashboardTheme = .green
    var pressureIsNormal = true

    var body: some View {
        HStack(spacing: 5) {
            Label("交换", systemImage: "externaldrive")
                .font(.system(size: 10.5, weight: .medium))
            Text(pressureIsNormal && (usedBytes ?? 0) > 0 ? "已用 · 多是之前换出的" : "已用").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            AnimatedReadingText(value: usedBytes, unit: .memory)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(theme.tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .help("交换文件里放的是内存紧的时候被挤到硬盘上的数据。挤出去以后不会马上搬回来,所以压力正常时这个数也可能好几 GB——它说明之前紧过,不代表现在不够用。真正要看的是右上角的内存压力。")
    }
}

/// 活动监视器同口径的一行总览:"已使用 20.1 GB / 24 GB · 还能用约 3.9 GB"。
/// 图里的"完全空闲"常常只有几百 MB——macOS 会把没用的内存拿去做文件缓存,需要时立刻腾出来——
/// 只看它会以为内存爆了,所以把"还能用"(文件缓存 + 完全空闲)单独写出来。
struct MemorySummaryView: View {
    var usedBytes: Double?
    var totalBytes: Double?
    var availableBytes: Double?
    var theme: DashboardTheme = .green

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("已使用").foregroundStyle(.secondary)
            AnimatedReadingText(value: usedBytes, unit: .memory)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("/").foregroundStyle(.tertiary)
            AnimatedReadingText(value: totalBytes, unit: .memory).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text("还能用约").foregroundStyle(.secondary)
            AnimatedReadingText(value: availableBytes, unit: .memory)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .help("和活动监视器同一个算法:已使用 = App 内存 + 联动 + 压缩。还能用 = 文件缓存 + 完全空闲——文件缓存是系统顺手拿来加速的,别的程序要内存时会立刻让出来,所以「完全空闲」少是正常的。")
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// A soft highlight plus enter/exit reporting for hover-aware blocks.
    @ViewBuilder
    func hoverable(id: String, targets: Set<String>, hoveredID: Binding<String?>,
                   onHover: ((String, Bool) -> Void)?) -> some View {
        if targets.contains(id) {
            // Negative padding on the highlight keeps the label layout identical
            // to non-hoverable labels.
            self
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hoveredID.wrappedValue == id ? 0.07 : 0))
                        .padding(.horizontal, -5)
                        .padding(.vertical, -3)
                }
                .background(HoverTracker { inside in
                    if inside { hoveredID.wrappedValue = id }
                    else if hoveredID.wrappedValue == id { hoveredID.wrappedValue = nil }
                    onHover?(id, inside)
                })
                .animation(.easeOut(duration: 0.12), value: hoveredID.wrappedValue == id)
        } else {
            self
        }
    }
}

/// Pointer enter/exit via an AppKit tracking area. `.activeAlways` matters:
/// WattsUp is an accessory app whose panel never activates it, and SwiftUI's
/// own hover tracking can stay silent in an inactive app.
struct HoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) { nsView.onChange = onChange }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        if nsView.isInside { nsView.onChange?(false) }
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private(set) var isInside = false
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }

        override func mouseEntered(with event: NSEvent) {
            guard !isInside else { return }
            isInside = true
            onChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            guard isInside else { return }
            isInside = false
            onChange?(false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, isInside {
                isInside = false
                onChange?(false)
            }
        }
    }
}

private extension View {
    @ViewBuilder func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
