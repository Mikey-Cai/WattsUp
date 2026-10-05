import AppKit
import SwiftUI
import WattsUpCore
import WattsUpHardware

/// Fetches per-process memory off the main thread and caches it briefly, so
/// moving between blocks does not re-run `top` (≈0.5 s) each time.
final class ProcessMemoryService {
    private let queue = DispatchQueue(label: "io.github.mikey-cai.wattsup.process-memory", qos: .userInitiated)
    private let lock = NSLock()
    private var _cached: ProcessMemoryReport?
    private var cached: ProcessMemoryReport? {
        get { lock.lock(); defer { lock.unlock() }; return _cached }
        set { lock.lock(); _cached = newValue; lock.unlock() }
    }
    private var inFlight = false
    private var waiters: [(ProcessMemoryReport) -> Void] = []
    private let maxAge: TimeInterval = 4

    /// Completion runs on the main queue.
    func fetch(_ completion: @escaping (ProcessMemoryReport) -> Void) {
        queue.async { [self] in
            if let cached, Date().timeIntervalSince(cached.timestamp) < maxAge {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            waiters.append(completion)
            guard !inFlight else { return }
            inFlight = true
            let report = ProcessMemorySampler.sample()
            // Only the rows that can be shown need full names.
            let memoryTop = report.top(by: .memory, limit: 10)
            let compressedTop = report.top(by: .compressed, limit: 10)
            var seen = Set<Int32>()
            let union = (memoryTop + compressedTop).filter { seen.insert($0.pid).inserted }
            let resolved = ProcessMemoryReport(timestamp: report.timestamp,
                                               rows: ProcessMemorySampler.resolveNames(union),
                                               source: report.source, note: report.note)
            cached = resolved
            inFlight = false
            let callbacks = waiters
            waiters.removeAll()
            DispatchQueue.main.async { callbacks.forEach { $0(resolved) } }
        }
    }

    /// Never blocks on a running `top`; safe from the main thread.
    var cachedReport: ProcessMemoryReport? { cached }
}

struct ProcessListRow: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let icon: NSImage?
    let memoryBytes: UInt64
    let compressedBytes: UInt64?
}

@MainActor
final class ProcessListModel: ObservableObject {
    @Published var target: MemoryHoverTarget = .physical
    @Published var rows: [ProcessListRow] = []
    @Published var isLoading = true
    @Published var note: String?
    @Published var source: String = "top"
    @Published var timestamp: Date?
    @Published var theme: DashboardTheme = .green
}

/// Rich tooltip next to the dashboard: the ten heaviest processes, like
/// Activity Monitor's Memory tab. It accepts the pointer, so moving from a
/// memory block onto the list keeps it open; it hides once the pointer has
/// left both the block and the list.
@MainActor
final class ProcessHoverController {
    private let service = ProcessMemoryService()
    private let model = ProcessListModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<ProcessListView>?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// What the list is showing. Not the same as where the pointer is.
    private var currentTarget: MemoryHoverTarget?
    /// The block the pointer is over now. Tracking areas do not promise that
    /// enter and exit alternate across areas (A.enter → B.enter → A.exit), so a
    /// late exit from an old block must not cancel or hide the new one.
    private var pointerTarget: MemoryHoverTarget?
    private var iconCache: [String: NSImage] = [:]
    private var generation = 0
    private var pointerInList = false
    weak var anchorWindow: NSWindow?

    /// Time to cross from a block to the list (an 8 pt gap plus the panel edge).
    private let leaveGrace: TimeInterval = 0.4

    func pointer(_ target: MemoryHoverTarget, inside: Bool, theme: DashboardTheme) {
        if inside {
            pointerTarget = target
            hideWork?.cancel()
            hideWork = nil
            showWork?.cancel()
            model.theme = theme
            if panel?.isVisible == true {
                show(target)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.pointerTarget == target else { return }
                    self.show(target)
                }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        } else {
            guard pointerTarget == target else { return }
            pointerTarget = nil
            showWork?.cancel()
            showWork = nil
            scheduleHide(after: leaveGrace)
        }
    }

    /// The pointer entered (true) or left (false) the list itself.
    private func pointerOnList(_ inside: Bool) {
        pointerInList = inside
        if inside {
            hideWork?.cancel()
            hideWork = nil
        } else {
            scheduleHide(after: 0.25)
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerTarget == nil, !self.pointerInList else { return }
            // Tracking areas miss an "enter" when the list appears under a still
            // pointer, so also ask where the pointer actually is.
            if let panel = self.panel, panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleHide(after: 0.25)   // check again; hides once the pointer is really gone
                return
            }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        hideWork?.cancel()
        hideWork = nil
        currentTarget = nil
        pointerTarget = nil
        pointerInList = false
        panel?.orderOut(nil)
    }

    private func show(_ target: MemoryHoverTarget) {
        guard let anchorWindow, anchorWindow.isVisible else { return }
        let switching = currentTarget != target
        currentTarget = target
        generation += 1
        let token = generation
        model.target = target
        if let cached = service.cachedReport, Date().timeIntervalSince(cached.timestamp) < 4 {
            apply(cached, target: target)
        } else if switching {
            // Rows picked and sorted for another metric must not sit under the new title.
            model.rows = []
            model.note = nil
            model.timestamp = nil
            model.isLoading = true
        } else if model.rows.isEmpty {
            model.isLoading = true
        }
        let panel = ensurePanel()
        panel.level = NSWindow.Level(rawValue: anchorWindow.level.rawValue + 1)
        layout(panel, near: anchorWindow)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        service.fetch { [weak self] report in
            guard let self, token == self.generation, let target = self.currentTarget else { return }
            self.apply(report, target: target)
            if let panel = self.panel, panel.isVisible, let anchor = self.anchorWindow {
                self.layout(panel, near: anchor, keepTop: true)
            }
        }
    }

    private func apply(_ report: ProcessMemoryReport, target: MemoryHoverTarget) {
        model.rows = report.top(by: target.sort, limit: 10).map { row in
            let app = NSRunningApplication(processIdentifier: row.pid)
            let localized = app?.bundleURL != nil ? app?.localizedName : nil
            let name = localized.flatMap { $0.isEmpty ? nil : $0 } ?? row.name
            return ProcessListRow(pid: row.pid, name: name, icon: icon(for: row, app: app),
                                  memoryBytes: row.memoryBytes, compressedBytes: row.compressedBytes)
        }
        model.note = report.note
        model.source = report.source
        model.timestamp = report.timestamp
        model.isLoading = false
    }

    private func icon(for row: ProcessMemoryRow, app: NSRunningApplication?) -> NSImage? {
        // Bundle-less daemons report a generic "exec" icon; show them all the
        // same way (a neutral gear) instead of mixing two placeholder styles.
        if let app, app.bundleURL != nil, let icon = app.icon { return icon }
        guard let path = row.path, let range = path.range(of: ".app/") else { return nil }
        // The outermost bundle: helpers inherit their app's icon, as in Activity Monitor.
        let bundle = String(path[..<range.lowerBound]) + ".app"
        if let cached = iconCache[bundle] { return cached }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        iconCache[bundle] = image
        return image
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: ProcessListView(model: model))
        hosting.sizingOptions = []
        let container = PointerTrackingView()
        container.onPointer = { [weak self] inside in self?.pointerOnList(inside) }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    private func layout(_ panel: NSPanel, near anchor: NSWindow, keepTop: Bool = false) {
        // A fresh controller measures the SwiftUI content as it is right now;
        // the displayed NSHostingView has sizingOptions = [] and reports no
        // useful fitting size.
        let ideal = NSHostingController(rootView: ProcessListView(model: model))
            .sizeThatFits(in: NSSize(width: 320, height: 2_000))
        let size = NSSize(width: 320, height: max(120, ceil(ideal.height)))
        let screen = anchor.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.frame
        var frame = PanelPlacement.sideTooltipFrame(size: size, panel: anchor.frame, pointer: NSEvent.mouseLocation,
                                                    visibleFrame: visible)
        if keepTop, panel.isVisible {
            // Grow downwards from the current top so the list does not jump.
            frame.origin.y = min(max(panel.frame.maxY - size.height, visible.minY + 4), visible.maxY - 4 - size.height)
            frame.origin.x = panel.frame.origin.x
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }
}

struct ProcessListView: View {
    @ObservedObject var model: ProcessListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: model.target.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.theme.tint)
                    .frame(width: 18)
                Text(model.target.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer(minLength: 4)
                Text("前 10")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Text("进程").frame(maxWidth: .infinity, alignment: .leading)
                columnHeader("内存", active: model.target.sort == .memory)
                columnHeader("压缩", active: model.target.sort == .compressed)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Divider().padding(.horizontal, 8)

            VStack(spacing: 0) {
                if model.isLoading && model.rows.isEmpty {
                    ForEach(0..<10, id: \.self) { index in placeholderRow(index) }
                } else if model.rows.isEmpty {
                    Text("没有读到进程数据")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        processRow(index: index, row: row)
                    }
                }
            }
            .padding(.vertical, 4)
            .opacity(model.isLoading && !model.rows.isEmpty ? 0.6 : 1)

            Divider().padding(.horizontal, 8)
            Text(footer)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .frame(width: 320, alignment: .topLeading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    private var footer: String {
        if let note = model.note { return note }
        let what = model.target.sort == .memory ? "按「内存」（与活动监视器同口径）从高到低" : "按被压缩的内存从高到低"
        return "\(what) · 数据来自 top"
    }

    private func columnHeader(_ title: String, active: Bool) -> some View {
        HStack(spacing: 2) {
            Text(title).fontWeight(active ? .semibold : .regular)
            if active { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
        }
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .frame(width: 68, alignment: .trailing)
    }

    private func processRow(index: Int, row: ProcessListRow) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .trailing)
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            Text(row.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("PID \(row.pid)")
            Text(Units.memory(Double(row.memoryBytes)))
                .font(.system(size: 10.5, weight: model.target.sort == .memory ? .semibold : .regular, design: .rounded))
                .foregroundStyle(model.target.sort == .memory ? Color.primary : Color.secondary)
                .frame(width: 68, alignment: .trailing)
            Text(row.compressedBytes.map { Units.memory(Double($0)) } ?? "—")
                .font(.system(size: 10.5, weight: model.target.sort == .compressed ? .semibold : .regular, design: .rounded))
                .foregroundStyle(model.target.sort == .compressed ? Color.primary : Color.secondary)
                .frame(width: 68, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
    }

    private func placeholderRow(_ index: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 16 + 14 + 6, height: 10)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07))
                .frame(width: CGFloat(80 + (index * 37) % 70), height: 10)
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 52, height: 10)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(width: 52, height: 10)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Reports the pointer entering and leaving its bounds, even though the
/// panel never becomes key (WattsUp is an accessory app).
private final class PointerTrackingView: NSView {
    var onPointer: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
