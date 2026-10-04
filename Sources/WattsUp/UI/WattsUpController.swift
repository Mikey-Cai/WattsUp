import AppKit
import Combine
import SwiftUI
import WattsUpCore

/// v0.3 window model: one non-activating, resizable NSPanel.
/// - Unpinned: hangs below the menu-bar icon, closes on a click elsewhere,
///   on Esc, or when another app/Space becomes active.
/// - Pinned: stays exactly where it is, floats above other windows, never
///   auto-closes, and can be dragged anywhere. Dragging an unpinned panel
///   detaches it, i.e. pins it in place (like a detached system popover).
/// Width and height are freely resizable in both modes. The last size and
/// the pinned frame are remembered in UserDefaults.
@MainActor
final class WattsUpController: NSObject, NSWindowDelegate {
    private let model: DashboardViewModel
    private let defaults: UserDefaults
    private var statusItem: NSStatusItem?
    private var panel: DashboardPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?
    private var isProgrammaticFrameChange = false
    private let hover = ProcessHoverController()

    private let sizeKey = "WattsUp.panelSize.v3"
    private let pinnedFrameKey = "WattsUp.pinnedFrame.v3"
    private let pinnedKey = "WattsUp.isPinned.v3"
    private let pinnedVisibleKey = "WattsUp.pinnedVisible.v3"
    private let legacyPopoverSizeKey = "WattsUp.popoverSize.v2"
    private let opacityKey = "WattsUp.floatingOpacity.v1"
    private let intervalKey = "WattsUp.refreshInterval.v1"
    private let preferredSize = NSSize(width: 650, height: 690)
    private let minimumSize = NSSize(width: 440, height: 340)

    init(model: DashboardViewModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        let savedInterval = defaults.double(forKey: intervalKey)
        if [1.0, 2.0, 5.0].contains(savedInterval) {
            model.setRefreshInterval(savedInterval)
        }
        if defaults.object(forKey: opacityKey) != nil {
            model.opacity = min(1, max(0.55, defaults.double(forKey: opacityKey)))
        }

        model.onTogglePin = { [weak self] in self?.togglePin() }
        model.onClose = { [weak self] in self?.closePanel() }
        model.onQuit = { NSApp.terminate(nil) }
        model.onOpacityChange = { [weak self] value in
            guard let self else { return }
            if self.model.isPinned { self.panel?.alphaValue = value }
            self.defaults.set(value, forKey: self.opacityKey)
        }
        model.onWindowDragBegan = { [weak self] in self?.hover.hide() }
        model.onCardDragBegan = { [weak self] in self?.hover.hide() }
        model.onMemoryHover = { [weak self] target, inside in
            guard let self else { return }
            self.hover.pointer(target, inside: inside, theme: self.model.theme)
        }

        model.$refreshInterval.dropFirst().sink { [weak self] value in
            guard let self else { return }
            self.defaults.set(value, forKey: self.intervalKey)
        }.store(in: &subscriptions)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "WattsUp：功耗与内存流向")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "WattsUp · 看电从哪来、到哪去"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismissIfTransient("space") }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.dismissIfTransient("activate \(activated?.bundleIdentifier ?? "?")") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        })

        if defaults.bool(forKey: "WattsUpDebugShowOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showPanel() }
        }
        // Debug-only: exercise the hover list without a pointer ("app"/"compressed"/"physical").
        if let raw = defaults.string(forKey: "WattsUpDebugHover"), let target = MemoryHoverTarget(rawValue: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                self.hover.pointer(target, inside: true, theme: self.model.theme)
            }
        }
        // Debug-only: draw the open panel into a PNG in the sandbox's temporary
        // folder, so layout can be checked while the screen is locked (screen
        // capture is refused then). Materials and blur do not render this way.
        if defaults.bool(forKey: "WattsUpDebugRender") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.renderPanelForDebug() }
        }
        // A panel that was pinned and open when WattsUp quit comes back where it was.
        if defaults.bool(forKey: pinnedKey) {
            model.isPinned = true
            if defaults.bool(forKey: pinnedVisibleKey) {
                // Give the status item a moment to be placed in the menu bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showPanel() }
            }
        }
    }

    func stop() {
        hover.hide()
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        subscriptions.removeAll()
        setVisible(false)
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(sender)
            return
        }
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = model.isVisible
        menu.addItem(refresh)
        let pin = NSMenuItem(title: model.isPinned ? "取消钉住" : "钉住浮窗", action: #selector(togglePinFromMenu), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 WattsUp", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func refreshNow() { model.onRefresh?() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func togglePinFromMenu() {
        if panel?.isVisible != true { showPanel() }
        togglePin()
    }

    // MARK: Show / hide

    private func showPanel() {
        let panel = ensurePanel()
        applyMode(to: panel)
        let target = targetFrame(for: panel)
        setFrame(target, on: panel)
        let alpha = model.isPinned ? model.opacity : 1
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = alpha
            }
        } else {
            panel.alphaValue = alpha
            panel.makeKeyAndOrderFront(nil)
        }
        // Ordering front may let AppKit adjust a titled window; insist on the
        // remembered/anchored frame.
        if panel.frame != target { setFrame(target, on: panel) }
        if model.isPinned {
            defaults.set(true, forKey: pinnedVisibleKey)
        } else {
            installOutsideClickMonitor()
            statusItem?.button?.highlight(true)
        }
        if defaults.bool(forKey: "WattsUpDebugLog") {
            let button = statusItem?.button
            let anchor = button?.window.map { $0.convertToScreen(button!.convert(button!.bounds, to: nil)) } ?? .zero
            let line = "WattsUp debug: pinned=\(model.isPinned) anchor=\(NSStringFromRect(anchor)) buttonWindow=\(NSStringFromRect(button?.window?.frame ?? .zero)) screen=\(NSStringFromRect(button?.window?.screen?.frame ?? .zero)) panel=\(NSStringFromRect(panel.frame))\n"
            FileHandle.standardError.write(Data(line.utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let root = panel.contentView?.superview ?? panel.contentView else { return }
                let w = panel.frame.width, h = panel.frame.height
                let probes: [(String, NSPoint)] = [
                    ("left edge", NSPoint(x: 2, y: h / 2)), ("right edge", NSPoint(x: w - 2, y: h / 2)),
                    ("top edge", NSPoint(x: w / 2, y: h - 2)), ("bottom edge", NSPoint(x: w / 2, y: 2)),
                    ("bottom-left corner", NSPoint(x: 4, y: 4)), ("top-right corner", NSPoint(x: w - 4, y: h - 4)),
                    ("header empty space", NSPoint(x: w / 2, y: h - 25)), ("card middle", NSPoint(x: w / 2, y: h / 2))
                ]
                for (name, point) in probes {
                    let hit = root.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil (falls through)"
                    FileHandle.standardError.write(Data("WattsUp debug: hit \(name) -> \(hit)\n".utf8))
                }
            }
        }
        hover.anchorWindow = panel
        setVisible(true)
        model.onRefresh?()
    }

    private func hidePanel() {
        hover.hide()
        removeOutsideClickMonitor()
        statusItem?.button?.highlight(false)
        guard let panel, panel.isVisible else {
            setVisible(false)
            return
        }
        saveFrame(of: panel)
        panel.orderOut(nil)
        if model.isPinned { defaults.set(false, forKey: pinnedVisibleKey) }
        setVisible(false)
    }

    /// The close (×) button: hide and fall back to the normal dropdown next time.
    private func closePanel() {
        hidePanel()
        if model.isPinned { setPinned(false) }
    }

    private func dismissIfTransient(_ reason: String) {
        guard !model.isPinned, panel?.isVisible == true else { return }
        if defaults.bool(forKey: "WattsUpDebugLog") {
            FileHandle.standardError.write(Data("WattsUp debug: auto-close (\(reason))\n".utf8))
        }
        hidePanel()
    }

    // MARK: Pinning

    private func togglePin() {
        guard let panel else { return }
        if model.isPinned {
            setPinned(false)
            applyMode(to: panel)
            // Re-attach under the menu-bar icon, keeping the user's size.
            let anchored = anchoredFrame(size: panel.frame.size)
            isProgrammaticFrameChange = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(anchored, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor in self?.isProgrammaticFrameChange = false }
            })
            panel.alphaValue = 1
            if panel.isVisible {
                installOutsideClickMonitor()
                statusItem?.button?.highlight(true)
            }
        } else {
            pinInPlace()
        }
    }

    /// Pin without moving: the panel stays exactly where it is now.
    private func pinInPlace() {
        guard let panel else { return }
        setPinned(true)
        applyMode(to: panel)
        removeOutsideClickMonitor()
        statusItem?.button?.highlight(false)
        defaults.set(panel.isVisible, forKey: pinnedVisibleKey)
        saveFrame(of: panel)
    }

    private func setPinned(_ pinned: Bool) {
        model.isPinned = pinned
        defaults.set(pinned, forKey: pinnedKey)
        if !pinned { defaults.set(false, forKey: pinnedVisibleKey) }
    }

    private func applyMode(to panel: DashboardPanel) {
        if model.isPinned {
            panel.level = .floating
            // Per NSWindow.h these are compatible: canJoinAllApplications joins
            // other apps' Stage Manager sets; stationary keeps it out of Exposé.
            panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
                                        .stationary, .ignoresCycle]
            panel.alphaValue = panel.isVisible ? model.opacity : panel.alphaValue
        } else {
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            if panel.isVisible { panel.alphaValue = 1 }
        }
    }

    // MARK: Outside clicks

    private func renderPanelForDebug() {
        guard let view = panel?.contentView else { NSLog("WattsUp debug render: no panel"); return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wattsup-panel.png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("WattsUp debug render: %@", url.path)
        } catch {
            NSLog("WattsUp debug render failed: %@", error.localizedDescription)
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        // Global monitors only see events going to other apps (or the desktop
        // and other menu-bar items), which is exactly "a click elsewhere".
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissIfTransient("outside click") }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: Geometry

    private func ensurePanel() -> DashboardPanel {
        if let panel { return panel }
        let size = savedSize()
        // Borderless on purpose. v0.2 used a titled panel with a transparent
        // title bar: those fully transparent pixels let clicks fall through to
        // the window behind, so the panel could not be dragged. Here every
        // interaction is ours: header drag (WindowDragArea) and edge/corner
        // resize handles (ResizeHandlesView).
        let panel = DashboardPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "WattsUp"
        // Cards have their own drag-to-reorder handles; only the header's empty
        // space (WindowDragArea) moves the window.
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.contentViewController = DashboardHostingController(
            rootView: DashboardHostView(model: model), size: size, minimumSize: minimumSize,
            onResizeBegan: { [weak self] in self?.hover.hide() },
            onResizeEnded: { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.saveFrame(of: panel)
                panel.invalidateShadow()
            })
        panel.contentMinSize = minimumSize
        // Set the size AFTER attaching the hosting controller: a SwiftUI
        // ScrollView has no useful intrinsic height for the panel to adopt.
        panel.setContentSize(size)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hidePanel() }
        self.panel = panel
        return panel
    }

    private func targetFrame(for panel: DashboardPanel) -> NSRect {
        if model.isPinned,
           let saved = PanelPlacement.validSavedFrame(defaults.string(forKey: pinnedFrameKey).map(NSRectFromString),
                                                       minimum: minimumSize) {
            return PanelPlacement.constrained(saved, to: visibleFrame(containing: saved))
        }
        return anchoredFrame(size: savedSize())
    }

    private func anchoredFrame(size: NSSize) -> NSRect {
        func topRight() -> NSRect {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
            let clamped = PanelPlacement.clampedSize(size, minimum: minimumSize, visibleFrame: visible)
            return NSRect(x: visible.maxX - clamped.width - 8, y: visible.maxY - clamped.height - 6,
                          width: clamped.width, height: clamped.height)
        }
        // Right after launch the (MenuBarAgent-hosted) status item may not be
        // laid out yet and reports a zero-height window at the screen origin.
        guard let button = statusItem?.button, let buttonWindow = button.window,
              buttonWindow.frame.height > 0,
              let screen = buttonWindow.screen ?? NSScreen.main else { return topRight() }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.frame.intersects(anchor), anchor.minY >= screen.visibleFrame.maxY - 4 else { return topRight() }
        return PanelPlacement.anchoredFrame(size: size, anchor: anchor, visibleFrame: screen.visibleFrame,
                                            minimum: minimumSize)
    }

    private func visibleFrame(containing frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { a, b in
            a.visibleFrame.intersection(frame).area < b.visibleFrame.intersection(frame).area
        } ?? NSScreen.main
        return screen?.visibleFrame ?? frame
    }

    private func savedSize() -> NSSize {
        for key in [sizeKey, legacyPopoverSizeKey] {
            if let raw = defaults.string(forKey: key) {
                let size = NSSizeFromString(raw)
                if size.width.isFinite, size.height.isFinite,
                   size.width >= minimumSize.width, size.height >= minimumSize.height {
                    return size
                }
            }
        }
        return preferredSize
    }

    private func setFrame(_ frame: NSRect, on panel: NSWindow) {
        isProgrammaticFrameChange = true
        panel.setFrame(frame, display: true)
        isProgrammaticFrameChange = false
    }

    private func saveFrame(of panel: NSWindow) {
        defaults.set(NSStringFromSize(panel.frame.size), forKey: sizeKey)
        if model.isPinned {
            defaults.set(NSStringFromRect(panel.frame), forKey: pinnedFrameKey)
        }
    }

    private func screensChanged() {
        guard let panel, panel.isVisible else { return }
        let frame = model.isPinned
            ? PanelPlacement.constrained(panel.frame, to: visibleFrame(containing: panel.frame))
            : anchoredFrame(size: panel.frame.size)
        setFrame(frame, on: panel)
    }

    private func setVisible(_ visible: Bool) {
        guard visible != model.isVisible else { return }
        model.isVisible = visible
        model.onVisibilityChange?(visible)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePanel()
        return false
    }

    func windowWillMove(_ notification: Notification) {
        hover.hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, !isProgrammaticFrameChange, panel.isVisible else { return }
        // Resizing from the left/bottom edge also moves the origin: not a drag.
        if panel.isUserResizing || panel.inLiveResize {
            return
        }
        // The user dragged an unpinned panel away from the menu bar: keep it
        // there, i.e. pin it in place.
        if !model.isPinned { pinInPlace() } else { saveFrame(of: panel) }
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, !isProgrammaticFrameChange, panel.isVisible else { return }
        hover.hide()
        // Saved once at the end of a handle drag; native live resizes save here.
        if !panel.isUserResizing { saveFrame(of: panel) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        saveFrame(of: panel)
        panel.invalidateShadow()
    }
}

final class DashboardPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// True while one of our edge/corner handles is being dragged.
    var isUserResizing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// A non-intrinsic container owns the viewport, so hosting a ScrollView can
/// never shrink the panel to the header's ideal height.
@MainActor
private final class DashboardHostingController: NSViewController {
    private let host: NSHostingController<DashboardHostView>
    private let initialSize: NSSize
    private let minimumSize: NSSize
    private let onResizeBegan: () -> Void
    private let onResizeEnded: () -> Void

    init(rootView: DashboardHostView, size: NSSize, minimumSize: NSSize,
         onResizeBegan: @escaping () -> Void, onResizeEnded: @escaping () -> Void) {
        host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        initialSize = size
        self.minimumSize = minimumSize
        self.onResizeBegan = onResizeBegan
        self.onResizeEnded = onResizeEnded
        super.init(nibName: nil, bundle: nil)
        // No preferredContentSize: AppKit would re-apply it when the panel is
        // first shown and undo the user's remembered size.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: initialSize))
        addChild(host)
        let content = host.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        let handles = ResizeHandlesView()
        handles.minimumSize = minimumSize
        handles.onResizeBegan = onResizeBegan
        handles.onResizeEnded = onResizeEnded
        handles.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handles)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            handles.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            handles.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            handles.topAnchor.constraint(equalTo: view.topAnchor),
            handles.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

/// Invisible resize handles along every edge (6 pt) and corner (16 pt) of the
/// borderless panel. Everything else passes straight through to SwiftUI.
private final class ResizeHandlesView: NSView {
    var minimumSize: NSSize = .zero
    var onResizeBegan: (() -> Void)?
    var onResizeEnded: (() -> Void)?
    private var activeEdges: ResizeEdges = []
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero
    private let edge: CGFloat = 6
    private let corner: CGFloat = 16

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return edges(at: local).isEmpty ? nil : self
    }

    private func edges(at point: NSPoint) -> ResizeEdges {
        PanelPlacement.edges(at: point, in: bounds.size, edge: edge, corner: corner)
    }

    private var cornerRects: [NSRect] {
        let w = bounds.width, h = bounds.height
        return [NSRect(x: 0, y: 0, width: corner, height: corner),
                NSRect(x: w - corner, y: 0, width: corner, height: corner),
                NSRect(x: 0, y: h - corner, width: corner, height: corner),
                NSRect(x: w - corner, y: h - corner, width: corner, height: corner)]
    }

    private var edgeRects: [NSRect] {
        let w = bounds.width, h = bounds.height
        return [NSRect(x: 0, y: corner, width: edge, height: max(0, h - corner * 2)),
                NSRect(x: w - edge, y: corner, width: edge, height: max(0, h - corner * 2)),
                NSRect(x: corner, y: 0, width: max(0, w - corner * 2), height: edge),
                NSRect(x: corner, y: h - edge, width: max(0, w - corner * 2), height: edge)]
    }

    override func draw(_ dirtyRect: NSRect) {
        // The rounded corners are fully transparent, and the window server
        // lets clicks on fully transparent pixels fall through to the window
        // behind. A practically invisible fill keeps the corner handles alive.
        NSColor.black.withAlphaComponent(0.012).setFill()
        for rect in cornerRects { NSBezierPath(rect: rect).fill() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        for rect in cornerRects + edgeRects where rect.width > 0 && rect.height > 0 {
            addTrackingArea(NSTrackingArea(rect: rect, options: [.cursorUpdate, .activeAlways], owner: self, userInfo: nil))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.cursor(for: edges(at: convert(event.locationInWindow, from: nil))).set()
    }

    static func cursor(for edges: ResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case [.left]: position = .left
            case [.right]: position = .right
            case [.top]: position = .top
            case [.bottom]: position = .bottom
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            case [.right, .bottom]: position = .bottomRight
            default: return .arrow
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if edges == [.left] || edges == [.right] { return .resizeLeftRight }
        if edges == [.top] || edges == [.bottom] { return .resizeUpDown }
        return edges.isEmpty ? .arrow : .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        guard !activeEdges.isEmpty else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        (window as? DashboardPanel)?.isUserResizing = true
        onResizeBegan?()
        Self.cursor(for: activeEdges).push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !activeEdges.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let bounds = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? startFrame
        let frame = PanelPlacement.resized(startFrame, edges: activeEdges,
                                           delta: CGSize(width: mouse.x - startMouse.x, height: mouse.y - startMouse.y),
                                           minimum: minimumSize, bounds: bounds)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    override func mouseUp(with event: NSEvent) {
        guard !activeEdges.isEmpty else { return }
        activeEdges = []
        NSCursor.pop()
        (window as? DashboardPanel)?.isUserResizing = false
        onResizeEnded?()
    }
}

private struct DashboardHostView: View {
    @ObservedObject var model: DashboardViewModel

    var body: some View {
        DashboardView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
