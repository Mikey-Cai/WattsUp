import AppKit
import Foundation
import WattsUpCore
import WattsUpHardware

/// A single serial queue owns all native handles; polls never overlap.
/// While the panel is visible it samples at the user's interval. While hidden
/// it only keeps a slow (60 s) tick, and only when a WattsUp desktop widget is
/// actually installed — otherwise it stops completely, as in v0.2.
final class SamplingService {
    private let queue = DispatchQueue(label: "io.github.mikey-cai.wattsup.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var timerInterval: Double = 0
    private var power: PowerSampler?
    private var memory: MemorySampler?
    private var bandwidth: MemoryBandwidthSampler?
    private var visible = false
    private var widgetInstalled = false
    private var interval: Double = 2
    private let backgroundInterval: Double = 60
    private var lastSampleTime: TimeInterval = 0
    private let widgetWriter = WidgetSnapshotWriter()
    var onSnapshot: ((HardwareSnapshot) -> Void)?

    func setVisible(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.visible != value else { return }
            if value {
                // With a widget installed the samplers survive in the background
                // with a 60 s baseline. Reusing it would mix a minute-long GPU and
                // bandwidth average with this instant's PSTR in the first frame.
                self.power = nil
                self.bandwidth = nil
            }
            self.visible = value
            self.reschedule(pollNow: value)
        }
    }

    /// Called from the main thread after asking WidgetKit what is installed.
    func setWidgetInstalled(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.widgetInstalled != value else { return }
            self.widgetInstalled = value
            self.reschedule(pollNow: value && !self.visible)
        }
    }

    func setInterval(_ value: Double) {
        guard [1.0, 2.0, 5.0].contains(value) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.interval = value
            self.reschedule(pollNow: false)
        }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self, self.visible,
                  ProcessInfo.processInfo.systemUptime - self.lastSampleTime > 0.25 else { return }
            self.poll()
        }
    }

    private func reschedule(pollNow: Bool) {
        let wanted: Double? = visible ? interval : (widgetInstalled ? backgroundInterval : nil)
        guard let wanted else {
            timer?.cancel()
            timer = nil
            timerInterval = 0
            power = nil
            memory = nil
            bandwidth = nil
            return
        }
        if power == nil { power = PowerSampler() }
        if memory == nil { memory = MemorySampler() }
        if bandwidth == nil { bandwidth = MemoryBandwidthSampler() }
        if pollNow { poll() }
        if timer == nil || timerInterval != wanted {
            timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + wanted, repeating: wanted,
                           leeway: .milliseconds(Int(wanted * (visible ? 100 : 250))))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timerInterval = wanted
            timer.resume()
        }
    }

    private func poll() {
        guard let power, let memory else { return }
        lastSampleTime = ProcessInfo.processInfo.systemUptime
        let value = HardwareSnapshot(timestamp: Date(), power: power.sample(), memory: memory.sample(),
                                     memoryBandwidth: bandwidth?.sample())
        widgetWriter.write(value.widgetSnapshot, force: !visible)
        guard visible else { return }
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(value) }
    }
}

extension HardwareSnapshot {
    /// Panel and widget level: by what is left, not the kernel's compressor-based level.
    var headroomLevel: MemoryPressureLevel {
        let b = memory.breakdown
        return .fromHeadroom(availableBytes: b.map { $0.cachedBytes + $0.freeBytes },
                             physicalBytes: b?.physicalBytes ?? memory.physicalBytes, fallback: memory.pressure)
    }

    var widgetSnapshot: WidgetSnapshot {
        let b = memory.breakdown
        // Same checks as the panel: stale, failed or over-budget branches are
        // not shown. `power.components` keeps the raw readings for diagnostics.
        let checked = PowerBreakdown.make(
            totalWatts: power.totalWatts,
            cpuEstimateWatts: power.components.first { $0.id == "cpu" }?.watts,
            gpuWatts: power.components.first { $0.id == "gpu" }?.watts,
            gpuPending: power.energyBaselinePending ?? false,
            cpuState: power.cpuState ?? .ok, gpuState: power.gpuState ?? .ok)
        return WidgetSnapshot(
            timestamp: timestamp,
            totalWatts: checked.totalWatts,
            cpuEstimateWatts: checked.plotted.first { $0.kind == .cpu }?.watts,
            gpuWatts: checked.plotted.first { $0.kind == .gpu }?.watts,
            memoryUsedBytes: b?.memoryUsedBytes,
            memoryTotalBytes: b?.physicalBytes ?? memory.physicalBytes,
            swapUsedBytes: memory.swapUsedBytes,
            pressure: headroomLevel.rawValue
        )
    }

    var display: DashboardSnapshot {
        let b = memory.breakdown
        let memoryItems = [
            FlowDisplayItem(id: "app", title: "App 内存", value: b.map { Double($0.appBytes) }, role: .appMemory, symbol: "app.dashed"),
            FlowDisplayItem(id: "wired", title: "联动（Wired）", value: b.map { Double($0.wiredBytes) }, role: .wired, symbol: "pin"),
            FlowDisplayItem(id: "compressed", title: "压缩", value: b.map { Double($0.compressedBytes) }, role: .compressed, symbol: "arrow.down.right.and.arrow.up.left"),
            FlowDisplayItem(id: "cache", title: "文件缓存", value: b.map { Double($0.cachedBytes) }, role: .fileCache, symbol: "doc.on.doc"),
            FlowDisplayItem(id: "free", title: "完全空闲", value: b.map { Double($0.freeBytes) }, role: .free, symbol: "leaf")
        ]
        let pressure = DisplayPressure(headroomLevel)
        let systemPressure = DisplayPressure(memory.pressure)
        let adjustment = b.map { "App 含系统会计余量 \($0.accountingAdjustmentBytes >= 0 ? "+" : "−")\(Units.memory(Double($0.accountingAdjustmentBytes.magnitude)))；各项为 VM 口径近似。" }
        let memoryNotes = ([adjustment].compactMap { $0 } + memory.errors).joined(separator: "\n")
        let powerNotes = (["PSTR 为系统传感器读数；不等同于插座功率。"] + power.diagnostics).joined(separator: "\n")
        return DashboardSnapshot(
            timestamp: timestamp,
            power: PowerDisplay(totalWatts: power.totalWatts,
                                cpuEstimateWatts: power.components.first { $0.id == "cpu" }?.watts,
                                gpuWatts: power.components.first { $0.id == "gpu" }?.watts,
                                gpuPending: power.energyBaselinePending ?? false,
                                cpuState: power.cpuState ?? .ok, gpuState: power.gpuState ?? .ok,
                                cpuBusy: power.cpuBusyFraction,
                                note: powerNotes),
            memory: MemoryDisplay(totalBytes: Units.scalarBytes(memory.physicalBytes) ?? 0,
                                  branches: memoryItems, swapUsedBytes: Units.scalarBytes(memory.swapUsedBytes),
                                  usedBytes: b.map { Double($0.memoryUsedBytes) },
                                  availableBytes: b.map { Double($0.cachedBytes + $0.freeBytes) },
                                  bandwidth: memoryBandwidth,
                                  pressure: pressure, systemPressure: systemPressure,
                                  note: memoryNotes.isEmpty ? nil : memoryNotes))
    }
}
