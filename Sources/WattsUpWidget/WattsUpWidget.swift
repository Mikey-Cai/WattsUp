import AppKit
import SwiftUI
import WattsUpCore
import WidgetKit

// Desktop widget. It never touches sensors: the menu-bar app samples and
// writes a small JSON file into the shared App Group container; this sandboxed
// extension only reads it.

struct WattsUpEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var isPlaceholder = false
}

struct WattsUpProvider: TimelineProvider {
    func placeholder(in context: Context) -> WattsUpEntry {
        WattsUpEntry(date: Date(), snapshot: .preview, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WattsUpEntry) -> Void) {
        let stored = Self.load()
        completion(WattsUpEntry(date: Date(), snapshot: stored ?? (context.isPreview ? .preview : nil),
                                isPlaceholder: stored == nil && context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WattsUpEntry>) -> Void) {
        let now = Date()
        let entry = WattsUpEntry(date: now, snapshot: Self.load())
        // The app also asks WidgetKit to reload after it writes; this is the fallback cadence.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(5 * 60))))
    }

    static func load() -> WidgetSnapshot? {
        guard let url = WidgetSnapshot.fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return WidgetSnapshot.decode(data)
    }
}

extension WidgetSnapshot {
    static var preview: WidgetSnapshot {
        WidgetSnapshot(timestamp: Date(), totalWatts: 18.6, cpuEstimateWatts: 3.1, gpuWatts: 0.8,
                       memoryUsedBytes: 17_179_869_184, memoryTotalBytes: 25_769_803_776,
                       swapUsedBytes: 1_288_490_189, pressure: "normal")
    }
}

private enum Format {
    static let posix = Locale(identifier: "en_US_POSIX")

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: value < 10 ? "%.1f" : "%.0f", locale: posix, value)
    }

    static func gigabytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let value = Double(bytes) / 1_073_741_824
        return String(format: value < 10 ? "%.1f" : "%.0f", locale: posix, value)
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let value = Double(bytes)
        if value < 1_073_741_824 { return String(format: "%.0f MB", locale: posix, value / 1_048_576) }
        return String(format: "%.1f GB", locale: posix, value / 1_073_741_824)
    }
}

private func pressureColor(_ pressure: String) -> Color {
    switch pressure {
    case "normal": return Color(nsColor: .systemGreen)
    case "warning": return Color(nsColor: .systemYellow)
    case "critical": return Color(nsColor: .systemRed)
    default: return .secondary
    }
}

private let accent = Color(hue: 0.36, saturation: 0.48, brightness: 0.73)

struct WattsUpWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    var entry: WattsUpEntry
    /// Only for offline preview rendering; WidgetKit supplies the family.
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var stale: Bool { snapshot.map { $0.isStale(now: entry.date) } ?? true }

    var body: some View {
        Group {
            switch family {
            case .systemMedium: medium
            default: small
            }
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        .containerBackground(for: .widget) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.02)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let snapshot, !stale, snapshot.pressure == "warning" || snapshot.pressure == "critical" {
                    // Same reminder as the app's memory card: a light wash.
                    LinearGradient(colors: [pressureColor(snapshot.pressure).opacity(0.16), .clear],
                                   startPoint: .bottomLeading, endPoint: .topTrailing)
                }
            }
        }
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("整机功耗", systemImage: "bolt.fill")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .labelStyle(.titleAndIcon)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Format.watts(snapshot?.totalWatts))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text("W")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            Spacer(minLength: 4)
            memoryLine
            MemoryBar(fraction: snapshot?.memoryUsedFraction, color: pressureColor(snapshot?.pressure ?? "unknown"))
                .frame(height: 6)
                .padding(.top, 5)
            footer.padding(.top, 6)
        }
        .opacity(stale && !entry.isPlaceholder ? 0.55 : 1)
    }

    private var memoryLine: some View {
        HStack(spacing: 4) {
            Circle().fill(pressureColor(snapshot?.pressure ?? "unknown")).frame(width: 6, height: 6)
            Text("内存").foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text("\(Format.gigabytes(snapshot?.memoryUsedBytes))/\(Format.gigabytes(snapshot?.memoryTotalBytes)) GB")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private var footer: some View {
        if snapshot == nil {
            Text("打开 WattsUp 开始更新")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        } else if stale {
            Text("WattsUp 未在运行")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        } else if let snapshot {
            HStack(spacing: 3) {
                Text("余量 \(snapshot.pressureTitle)")
                Spacer(minLength: 2)
                Text(snapshot.timestamp, style: .time)
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Medium

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Label("整机功耗", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(Format.watts(snapshot?.totalWatts))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    Text("W")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
                Spacer(minLength: 4)
                detailRow("CPU（估计）", Format.watts(snapshot?.cpuEstimateWatts) + " W", symbol: "cpu")
                detailRow("GPU", Format.watts(snapshot?.gpuWatts) + " W", symbol: "square.stack.3d.up")
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Label("内存", systemImage: "memorychip")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                    Spacer(minLength: 2)
                    statusStamp
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(Format.gigabytes(snapshot?.memoryUsedBytes))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    Text("/ \(Format.gigabytes(snapshot?.memoryTotalBytes)) GB")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.top, 4)
                MemoryBar(fraction: snapshot?.memoryUsedFraction, color: pressureColor(snapshot?.pressure ?? "unknown"))
                    .frame(height: 6)
                    .padding(.top, 6)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Circle().fill(pressureColor(snapshot?.pressure ?? "unknown")).frame(width: 6, height: 6)
                    Text("余量 \(snapshot?.pressureTitle ?? "未知")")
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                detailRow("交换已用", Format.memory(snapshot?.swapUsedBytes), symbol: "externaldrive")
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(stale && !entry.isPlaceholder ? 0.55 : 1)
    }

    /// Update time, or why there is nothing fresh to show.
    @ViewBuilder
    private var statusStamp: some View {
        Group {
            if snapshot == nil {
                Text("未开始")
            } else if stale {
                Text("未在运行")
            } else if let snapshot {
                Text(snapshot.timestamp, style: .time)
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private func detailRow(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(.secondary).frame(width: 13)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct MemoryBar: View {
    var fraction: Double?
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(color.opacity(0.85))
                    .frame(width: proxy.size.width * min(1, max(0, fraction ?? 0)))
            }
        }
    }
}

struct WattsUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: WattsUpProvider()) { entry in
            WattsUpWidgetView(entry: entry)
        }
        .configurationDisplayName("WattsUp 功耗与内存")
        .description("整机功耗、内存占用与内存压力。数据由菜单栏里的 WattsUp 每分钟更新。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if !WATTSUP_WIDGET_PREVIEW_HARNESS
@main
struct WattsUpWidgetBundle: WidgetBundle {
    var body: some Widget {
        WattsUpWidget()
    }
}
#endif
