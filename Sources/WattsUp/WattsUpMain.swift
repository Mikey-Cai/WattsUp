import AppKit
import Darwin
import Foundation
import WattsUpCore
import WattsUpHardware

@main
struct WattsUpMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // "--command" (or -h) runs a CLI tool. Anything else is left to the
        // UserDefaults argument domain ("-Key value"), e.g. for screenshots:
        //   open WattsUp.app --args -AppleInterfaceStyle Dark -WattsUpDebugPressure warning
        if let first = args.first, first.hasPrefix("--") || first == "-h" {
            runCommand(args)
            return
        }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func runCommand(_ args: [String]) {
        switch args {
        case ["--probe"]:
            printJSON(PowerSampler().probe())
        case ["--dump-json"]:
            let sampler = PowerSampler()
            let bandwidth = MemoryBandwidthSampler()
            _ = sampler.sample() // IOReport needs two timestamps, not a guessed power.
            _ = bandwidth.sample()
            Thread.sleep(forTimeInterval: 1)
            printJSON(HardwareSnapshot(timestamp: Date(), power: sampler.sample(), memory: MemorySampler().sample(),
                                       memoryBandwidth: bandwidth.sample()))
        case ["--measure-overhead"]:
            measureOverhead()
        case ["--processes"]:
            let report = ProcessMemorySampler.sample()
            struct Listing: Encodable {
                let source: String
                let note: String?
                let byMemory: [ProcessMemoryRow]
                let byCompressed: [ProcessMemoryRow]
            }
            printJSON(Listing(source: report.source, note: report.note,
                              byMemory: ProcessMemorySampler.resolveNames(report.top(by: .memory)),
                              byCompressed: ProcessMemorySampler.resolveNames(report.top(by: .compressed))))
        case ["--widget-snapshot"]:
            let sampler = PowerSampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 1)
            let snapshot = HardwareSnapshot(timestamp: Date(), power: sampler.sample(), memory: MemorySampler().sample()).widgetSnapshot
            WidgetSnapshotWriter().write(snapshot, force: true)
            printJSON(snapshot)
            fputs("App Group 文件：\(WidgetSnapshot.fileURL()?.path ?? "不可用")\n", stderr)
        case ["--cross-check-gpu"]:
            crossCheckGPU()
        case ["--help"], ["-h"]:
            print("""
            WattsUp 0.3 — 本地功耗与内存桑基图
            无参数              启动菜单栏 App
            --probe            枚举 SMC 所有键及 flt/功率相关值，JSON 输出后退出
            --dump-json        采样一次全部读数（含 1 秒 IOReport 差值）后退出
            --measure-overhead 默认 2 秒间隔运行 6 次采样，报告本进程 CPU 用时
            --processes        列出内存 / 压缩内存占用前 10 的进程（JSON）
            --widget-snapshot  采样一次并写入桌面小组件的 App Group 文件
            --cross-check-gpu  用已安装的 root 助手（powermetrics）交叉核对 IOReport GPU 功耗，约 8 秒
            """)
        default:
            fputs("不支持的参数；使用 --help 查看用法。\n", stderr)
            exit(64)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            fputs("JSON 编码失败：\(error)\n", stderr)
            exit(1)
        }
    }

    /// Optional cross-check against the root helper's powermetrics output.
    /// The app itself never depends on it.
    private static func crossCheckGPU() {
        let want = "/var/tmp/wattsup.want"
        let plist = URL(fileURLWithPath: "/var/tmp/wattsup/power.plist")
        let sampler = PowerSampler()
        _ = sampler.sample()
        struct Pair: Encodable {
            let ioReportGPUWatts: Double?
            let powermetricsGPUWatts: Double?
            let powermetricsFileAgeSeconds: Double?
        }
        var pairs: [Pair] = []
        for _ in 0..<6 {
            // Like touch(1): utimes(NULL) only needs write access, which matters
            // because the helper's flag file is root-owned in sticky /var/tmp.
            if utimes(want, nil) != 0 {
                let fd = open(want, O_WRONLY | O_CREAT, 0o666)
                if fd >= 0 { close(fd) }
            }
            Thread.sleep(forTimeInterval: 1.3)
            let gpu = sampler.sample().components.first { $0.id == "gpu" }?.watts
            var helperWatts: Double?
            var age: Double?
            if let data = try? Data(contentsOf: plist),
               let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let processor = root["processor"] as? [String: Any] {
                // powermetrics reports milliwatts under processor/gpu_power.
                if let mw = (processor["gpu_power"] as? NSNumber)?.doubleValue { helperWatts = mw / 1_000 }
                if let modified = (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.modificationDate] as? Date {
                    age = Date().timeIntervalSince(modified)
                }
            }
            pairs.append(Pair(ioReportGPUWatts: gpu, powermetricsGPUWatts: helperWatts, powermetricsFileAgeSeconds: age))
        }
        struct Result: Encodable {
            let note: String
            let pairs: [Pair]
        }
        printJSON(Result(note: "两者采样窗口不同（IOReport ≈1.3 s，powermetrics 1 s），只看量级与趋势；助手没在运行时 powermetrics 一列为空。",
                         pairs: pairs))
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func measureOverhead() {
        let wallStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = cpuSeconds()
        let power = PowerSampler()
        let memory = MemorySampler()
        var last: HardwareSnapshot?
        for index in 0..<6 {
            if index > 0 { Thread.sleep(forTimeInterval: 2) }
            last = HardwareSnapshot(timestamp: Date(), power: power.sample(), memory: memory.sample())
        }
        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        let cpu = cpuSeconds() - cpuStart
        struct Measurement: Encodable {
            let scope: String
            let intervalSeconds: Double
            let sampleCount: Int
            let wallSeconds: Double
            let cpuSeconds: Double
            let percentOfOneCore: Double
            let lastSnapshot: HardwareSnapshot?
        }
        printJSON(Measurement(scope: "采样层；不包含 GUI 渲染。权限缺失会使本次成本低于完整传感器可用时。",
                              intervalSeconds: 2, sampleCount: 6, wallSeconds: wall,
                              cpuSeconds: cpu, percentOfOneCore: cpu / wall * 100,
                              lastSnapshot: last))
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let model = DashboardViewModel()
    private let sampler = SamplingService()
    private let widgetPresence = WidgetPresenceMonitor()
    private var controller: WattsUpController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A window-less accessory app is a candidate for automatic termination;
        // that would silently freeze the desktop widget's numbers.
        ProcessInfo.processInfo.disableAutomaticTermination("WattsUp 在菜单栏与桌面小组件中持续显示读数")
        // Debug-only override (argument domain, nothing is persisted) so the
        // pressure wash can be checked without starving the Mac of memory.
        let debugPressure: DisplayPressure? = {
            switch UserDefaults.standard.string(forKey: "WattsUpDebugPressure") {
            case "warning": return .warning
            case "critical": return .critical
            case "normal": return .normal
            default: return nil
            }
        }()
        sampler.onSnapshot = { [weak self] snapshot in
            var display = snapshot.display
            if let debugPressure { display.memory.pressure = debugPressure }
            self?.model.snapshot = display
        }
        model.onVisibilityChange = { [weak self] visible in
            self?.sampler.setVisible(visible)
            // Opening/closing the panel is a cheap moment to re-check widgets.
            if !visible { self?.widgetPresence.check() }
        }
        model.onRefreshIntervalChange = { [weak self] seconds in self?.sampler.setInterval(seconds) }
        model.onRefresh = { [weak self] in self?.sampler.refresh() }
        widgetPresence.onChange = { [weak self] installed in self?.sampler.setWidgetInstalled(installed) }
        // Debug-only: check both appearances without touching system settings.
        switch UserDefaults.standard.string(forKey: "WattsUpDebugAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let controller = WattsUpController(model: model)
        self.controller = controller
        controller.start()
        widgetPresence.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        widgetPresence.stop()
        sampler.setVisible(false)
        controller?.stop()
    }
}
