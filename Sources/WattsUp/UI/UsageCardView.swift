import SwiftUI
import WattsUpCore

/// Rows of the 使用率 card. A row appears only when this Mac has a source for
/// it; a source still waiting for its second snapshot says 读取中….
struct UsageRowsView: View {
    var usage: UsageReading?
    var theme: DashboardTheme = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage, !usage.isEmpty {
                if usage.cpuBusy != nil || usage.isPending("cpu") { cpuRow(usage) }
                if let gpu = usage.gpuBusy { gpuRow(gpu) }
                if usage.diskReadBytesPerSecond != nil || usage.isPending("disk") {
                    rateRow(title: "磁盘", symbol: "internaldrive", pending: usage.isPending("disk"),
                            first: ("读", usage.diskReadBytesPerSecond), second: ("写", usage.diskWriteBytesPerSecond),
                            help: "所有物理硬盘（内置和外接）合计的读写速度：存储驱动的累计字节数（IOBlockStorageDriver）在两次采样之间的平均值。挂载的磁盘映像不算，因为它的读写会落到存放映像文件的硬盘上，算进来就重复了。")
                }
                if usage.networkReceivedBytesPerSecond != nil || usage.isPending("network") {
                    rateRow(title: "网络", symbol: "network", pending: usage.isPending("network"),
                            first: ("下载", usage.networkReceivedBytesPerSecond), second: ("上传", usage.networkSentBytesPerSecond),
                            help: "有线和 Wi-Fi 网卡合计的收发速度，包括局域网里传文件；是两次采样之间的平均值。本机回环和 VPN / 代理的虚拟网卡（utun）不算——走代理的流量在真实网卡上已经算过一次。")
                }
            } else {
                Text(usage == nil ? "读取中…" : "这台 Mac 上读不到使用率数据")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 9)
            }
        }
    }

    private func cpuRow(_ usage: UsageReading) -> some View {
        let color = DisplayColorRole.cpu.color(theme: theme)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label("CPU", systemImage: "cpu").font(.system(size: 10.5, weight: .medium))
                Text("所有核心平均").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if usage.cpuBusy == nil { Text("读取中…").foregroundStyle(.secondary) }
                AnimatedReadingText(value: usage.cpuBusy, unit: .percent, placeholder: "")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            UsageBar(fraction: usage.cpuBusy, color: color)
            if let groups = usage.coreGroups, groups.count > 1 {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 3) {
                                Text(CPUClusters.title(forLevelName: group.name)).foregroundStyle(.secondary)
                                Text("×\(group.cpuCount)").foregroundStyle(.tertiary)
                                Spacer(minLength: 2)
                                AnimatedReadingText(value: group.busy, unit: .percent, placeholder: "…")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            // Highest-performance kind first, drawn strongest.
                            UsageBar(fraction: group.busy, color: color.opacity(1 - 0.22 * Double(index)), height: 3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .help(groupsHelp(groups))
            }
        }
        .usageRow(theme: theme)
        .help("所有核心的平均占用率，来自内核按核心累计的忙碌时间（用户态 + 系统态），和「电力去向」里 CPU 下面的忙碌度是同一个数。")
    }

    private func gpuRow(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label("GPU", systemImage: "square.stack.3d.up").font(.system(size: 10.5, weight: .medium))
                Text("显卡驱动统计").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                AnimatedReadingText(value: fraction, unit: .percent)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            UsageBar(fraction: fraction, color: DisplayColorRole.gpu.color(theme: theme))
        }
        .usageRow(theme: theme)
        .help("显卡驱动自己报告的忙碌比例（IOAccelerator 的「Device Utilization %」），是驱动统计的最近一小段时间，不需要额外权限。")
    }

    private func rateRow(title: String, symbol: String, pending: Bool,
                         first: (label: String, value: Double?), second: (label: String, value: Double?),
                         help: String) -> some View {
        HStack(spacing: 5) {
            Label(title, systemImage: symbol).font(.system(size: 10.5, weight: .medium))
            Spacer(minLength: 4)
            if pending {
                Text("读取中…").foregroundStyle(.secondary)
            } else {
                Text(first.label).foregroundStyle(.secondary)
                AnimatedReadingText(value: first.value, unit: .rate)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(minWidth: 72, alignment: .trailing)
                Text(second.label).foregroundStyle(.secondary).padding(.leading, 6)
                AnimatedReadingText(value: second.value, unit: .rate)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .usageRow(theme: theme)
        .help(help)
    }

    private func groupsHelp(_ groups: [UsageReading.CoreGroup]) -> String {
        let list = groups.map { "\(CPUClusters.title(forLevelName: $0.name)) \($0.cpuCount) 个" }.joined(separator: "、")
        return "这台 Mac 有 \(groups.count) 类核心：\(list)。分类来自系统设备树，和内核报告的核心数对得上才分开显示。后台任务一般跑在能效核上，前台的重活优先交给性能更高的核心。"
    }
}

/// A thin proportional bar; an unknown value draws only the track.
struct UsageBar: View {
    var fraction: Double?
    var color: Color
    var height: Double = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                if let fraction, fraction.isFinite {
                    Capsule().fill(color)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                        .animation(readingAnimation, value: fraction)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private extension View {
    func usageRow(theme: DashboardTheme) -> some View {
        self
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(theme.tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .combine)
    }
}
