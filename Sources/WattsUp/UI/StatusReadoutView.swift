import AppKit
import WattsUpCore

/// A single, persistent drawing surface inside NSStatusBarButton. It never
/// receives mouse events, so AppKit keeps the original left/right-click path.
@MainActor
final class StatusReadoutView: NSView {
    private let renderer: StatusReadoutRenderer
    private var settings = StatusReadoutSettings()
    private var values = StatusReadoutValues()

    init(physicalBytes: UInt64) {
        renderer = StatusReadoutRenderer(physicalBytes: physicalBytes)
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(settings: StatusReadoutSettings, values: StatusReadoutValues) -> CGFloat {
        if self.settings != settings || self.values != values {
            self.settings = settings
            self.values = values
            needsDisplay = true
        }
        return renderer.width(for: settings.style)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        renderer.draw(in: bounds, settings: settings, values: values,
                      highlighted: (superview as? NSStatusBarButton)?.isHighlighted == true)
    }
}

/// Shared by the live view and offscreen debug PNGs; only text and tiny paths,
/// no hosting view, animations, image replacement, sampling, or display timer.
@MainActor
struct StatusReadoutRenderer {
    let formatter: StatusReadoutFormatter
    private let gridFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    private let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)
    private let singleFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private let labelWidth: CGFloat
    private let gridValueWidth: CGFloat
    private let powerWidth: CGFloat
    private let memoryWidth: CGFloat
    private let barWidth: CGFloat = 28
    private let padding: CGFloat = 6
    private let columnGap: CGFloat = 12

    init(physicalBytes: UInt64) {
        let formatter = StatusReadoutFormatter(physicalBytes: physicalBytes)
        self.formatter = formatter
        func measured(_ strings: [String], font: NSFont) -> CGFloat {
            ceil(strings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        }
        labelWidth = measured(StatusReadoutMetric.allCases.map(\.shortTitle), font: labelFont)
        gridValueWidth = measured(StatusReadoutMetric.allCases.flatMap { formatter.widthCandidates(for: $0) }, font: gridFont)
        powerWidth = measured(formatter.widthCandidates(for: .power), font: singleFont)
        memoryWidth = measured(formatter.widthCandidates(for: .memory), font: singleFont)
    }

    private var cellWidth: CGFloat { labelWidth + 4 + gridValueWidth + 6 + barWidth }

    func width(for style: StatusReadoutStyle) -> CGFloat {
        switch style {
        case .twoLines: return padding * 2 + cellWidth * 2 + columnGap
        case .singleLine: return padding * 2 + 10 + 5 + powerWidth + 9 + memoryWidth
        case .iconOnly: return 24
        }
    }

    func draw(in bounds: NSRect, settings: StatusReadoutSettings, values: StatusReadoutValues, highlighted: Bool = false) {
        let primary: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        switch settings.style {
        case .iconOnly:
            bolt(circled: true, in: NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18), color: primary)
        case .singleLine:
            bolt(circled: false, in: NSRect(x: padding, y: bounds.midY - 6, width: 10, height: 12), color: primary)
            let powerX = padding + 15
            text(formatter.text(for: .power, values: values), right: powerX + powerWidth,
                 centerY: bounds.midY, font: singleFont, color: primary)
            text(formatter.text(for: .memory, values: values), right: powerX + powerWidth + 9 + memoryWidth,
                 centerY: bounds.midY, font: singleFont, color: memoryColor(values, primary: primary))
        case .twoLines:
            for (index, metric) in settings.slots.enumerated() {
                let x = padding + CGFloat(index % 2) * (cellWidth + columnGap)
                let y = bounds.midY + (index < 2 ? 5.5 : -5.5)
                let value = formatter.text(for: metric, values: values)
                let fraction = formatter.fraction(for: metric, values: values, powerCeiling: settings.powerCeiling)
                let color = metric == .memory ? memoryColor(values, primary: primary) : primary
                text(metric.shortTitle, left: x, centerY: y, font: labelFont, color: primary.withAlphaComponent(0.72))
                text(value, right: x + labelWidth + 4 + gridValueWidth, centerY: y, font: gridFont,
                     color: fraction == nil ? primary.withAlphaComponent(0.5) : color)
                let track = NSRect(x: x + cellWidth - barWidth, y: y - 1.25, width: barWidth, height: 2.5)
                primary.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.25, yRadius: 1.25).fill()
                if let fraction, fraction > 0 {
                    color.withAlphaComponent(0.9).setFill()
                    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                    width: track.width * fraction, height: track.height),
                                 xRadius: 1.25, yRadius: 1.25).fill()
                }
            }
        }
    }

    private func memoryColor(_ values: StatusReadoutValues, primary: NSColor) -> NSColor {
        guard formatter.text(for: .memory, values: values) != "—" else { return primary.withAlphaComponent(0.5) }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Darker ink in light menus; brighter ink in dark menus. Only memory
        // is semantic color; every other reading follows the menu appearance.
        switch values.pressure {
        case .normal: return dark ? NSColor(red: 0.44, green: 0.86, blue: 0.58, alpha: 1)
            : NSColor(red: 0.12, green: 0.43, blue: 0.24, alpha: 1)
        case .warning: return dark ? NSColor(red: 1, green: 0.78, blue: 0.32, alpha: 1)
            : NSColor(red: 0.56, green: 0.35, blue: 0.03, alpha: 1)
        case .critical: return dark ? NSColor(red: 1, green: 0.48, blue: 0.48, alpha: 1)
            : NSColor(red: 0.77, green: 0.13, blue: 0.17, alpha: 1)
        case .unknown: return primary
        }
    }

    private func text(_ string: String, left: CGFloat? = nil, right: CGFloat? = nil,
                      centerY: CGFloat, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: NSPoint(x: left ?? ((right ?? 0) - size.width), y: centerY - size.height / 2),
                                 withAttributes: attributes)
    }

    private func bolt(circled: Bool, in rect: NSRect, color: NSColor) {
        // A tiny vector bolt keeps both live and offscreen rendering identical.
        // NSImage's SF Symbol resolution registers with WindowServer even for
        // a bitmap context, which aborts in a headless/locked build session.
        color.setFill()
        color.setStroke()
        if circled {
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.8, dy: 0.8))
            circle.lineWidth = 1.15
            circle.stroke()
        }
        let area = circled ? rect.insetBy(dx: 4.4, dy: 3.2) : rect.insetBy(dx: 1, dy: 0)
        let vertices: [(CGFloat, CGFloat)] = [(0.63, 1), (0.04, 0.42), (0.43, 0.42),
                                               (0.30, 0), (0.96, 0.60), (0.56, 0.60)]
        let path = NSBezierPath()
        for (index, vertex) in vertices.enumerated() {
            let point = NSPoint(x: area.minX + vertex.0 * area.width, y: area.minY + vertex.1 * area.height)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.fill()
    }

    /// Explicit bitmap context works while locked: it never captures a screen
    /// or needs a visible window. Solid menu backgrounds approximate wallpaper.
    func png(settings: StatusReadoutSettings, values: StatusReadoutValues, dark: Bool) throws -> Data {
        let size = NSSize(width: width(for: settings.style), height: 24)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        appearance.performAsCurrentDrawingAppearance {
            NSColor(white: dark ? 0.12 : 0.94, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            draw(in: NSRect(origin: .zero, size: size), settings: settings, values: values)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    static func renderDebugMatrix() throws -> URL {
        // Deterministic fixtures, not measurements. The same formatter, colors,
        // geometry and drawing function are used by the live menu-bar view.
        let physical = UInt64(24 * Units.bytesPerGiB)
        let renderer = StatusReadoutRenderer(physicalBytes: physical)
        var values = StatusReadoutValues(watts: 18, availableBytes: 9.2 * Units.bytesPerGiB, cpuBusy: 0.37, gpuBusy: 0.62)
        func level(_ bytes: Double) -> MemoryPressureLevel {
            .fromHeadroom(availableBytes: UInt64(bytes), physicalBytes: physical, fallback: .unknown)
        }
        values.pressure = level(values.availableBytes!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WattsUp-status-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var paths: [String] = []
        func write(_ name: String, settings: StatusReadoutSettings, values: StatusReadoutValues, dark: Bool) throws {
            let url = directory.appendingPathComponent(name + ".png")
            try renderer.png(settings: settings, values: values, dark: dark).write(to: url, options: .atomic)
            paths.append(url.path)
        }
        for style in StatusReadoutStyle.allCases {
            for dark in [false, true] {
                try write("\(style.rawValue)-\(dark ? "dark" : "light")", settings: .init(style: style), values: values, dark: dark)
            }
        }
        values.availableBytes = 1.2 * Units.bytesPerGiB
        values.pressure = level(values.availableBytes!)
        for dark in [false, true] {
            try write("twoLines-critical-\(dark ? "dark" : "light")", settings: .init(), values: values, dark: dark)
        }
        try write("twoLines-unavailable-light", settings: .init(), values: .init(), dark: false)
        try write("twoLines-maximum-light", settings: .init(),
                  values: .init(watts: 2000, availableBytes: Double(physical), cpuBusy: 1, gpuBusy: 1, pressure: .normal), dark: false)
        try ("Deterministic 24 GB fixtures; 2x PNG; logical height 24 pt.\n" + paths.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
        return directory
    }
}
