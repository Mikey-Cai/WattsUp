import AppKit
import SwiftUI
import WattsUpCore

struct DashboardView: View {
    @ObservedObject var model: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    /// The card being dragged, how far it is drawn from its slot, and the part
    /// of that offset that came from swaps (the rest is the pointer's travel).
    @State private var draggedCard: DashboardCard?
    @State private var dragOffset = 0.0
    @State private var dragCorrection = 0.0
    @State private var cardHeights: [DashboardCard: Double] = [:]
    private let headerHeight = 50.0
    private let cardSpacing = 13.0

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .frame(height: headerHeight)
                ScrollView {
                    VStack(spacing: 0) {
                        cardsSection
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(minHeight: max(0, viewport.size.height - headerHeight), alignment: .top)
                        settings
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 20)
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(model.theme.tint)
        .environment(\.panelFrost, model.glassFrost)
        .background {
            // Only the glass changes with the 玻璃 slider; text and charts stay fully opaque.
            ZStack {
                PanelGlass(frost: model.glassFrost)
                Color(nsColor: .windowBackgroundColor).opacity(0.38 * model.glassFrost)
                LinearGradient(colors: [model.theme.tint.opacity((colorScheme == .dark ? 0.16 : 0.12) * (0.35 + 0.65 * model.glassFrost)),
                                        model.theme.tint.opacity((colorScheme == .dark ? 0.08 : 0.04) * (0.35 + 0.65 * model.glassFrost))],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .animation(.easeOut(duration: 0.15), value: model.glassFrost)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.15 : 0.62), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.theme.tint)
                .frame(width: 29, height: 29)
                .background(model.theme.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text("WattsUp")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Spacer()
            Button { model.onTogglePin?() } label: {
                Label(model.isPinned ? "已钉住" : "钉住", systemImage: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(model.isPinned ? model.theme.tint.opacity(0.15) : Color.primary.opacity(0.045), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "取消钉住：回到菜单栏图标下方，点别处自动收起" : "钉住：留在当前位置、保持置顶、不自动收起")
            if model.isPinned {
                Button { model.onClose?() } label: { Image(systemName: "xmark") }
                    .buttonStyle(SoftIconButtonStyle())
                    .help("关闭浮窗")
                    .accessibilityLabel("关闭浮窗")
            }
        }
        // Empty parts of the header move the window (and detach it = pin).
        .background(WindowDragArea(onDragBegan: { model.onWindowDragBegan?() }))
    }

    @ViewBuilder
    private var cardsSection: some View {
        VStack(spacing: cardSpacing) {
            if let snapshot = model.snapshot {
                ForEach(model.visibleCards) { card in
                    let dragging = draggedCard == card
                    Group {
                        switch card {
                        case .memory: memoryCard(snapshot.memory)
                        case .power: powerCard(snapshot.power)
                        case .usage: usageCard(snapshot.usage)
                        }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: CardHeightKey.self, value: [card: Double(proxy.size.height)])
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(model.theme.tint.opacity(dragging ? 0.5 : 0), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .scaleEffect(dragging ? 1.012 : 1)
                    .shadow(color: .black.opacity(dragging ? 0.16 : 0), radius: 16, y: 7)
                    .offset(y: dragging ? dragOffset : 0)
                    .zIndex(dragging ? 1 : 0)
                    // The dragged card's slot change is cancelled out by the offset
                    // correction in the same frame, so it must not animate; the
                    // card making room does.
                    .transaction { if dragging { $0.animation = nil } }
                    .gesture(cardDrag(card))
                }
            } else {
                waitingCard
            }
        }
        .coordinateSpace(name: "cards")
        .onPreferenceChange(CardHeightKey.self) { cardHeights = $0 }
        .onChange(of: model.isVisible) { _, visible in
            // A drag cut short by the panel closing never reaches onEnded.
            if !visible { draggedCard = nil; dragOffset = 0; dragCorrection = 0 }
        }
    }

    /// The whole card is the handle: it follows the pointer, and the other card
    /// slides out of the way as soon as the dragged one crosses its middle.
    private func cardDrag(_ card: DashboardCard) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("cards"))
            .onChanged { value in
                if draggedCard != card {
                    draggedCard = card
                    dragCorrection = 0
                    NSCursor.closedHand.set()
                    model.onCardDragBegan?()
                }
                let order = model.visibleCards
                guard let index = order.firstIndex(of: card) else { return }
                let offset = dragCorrection + Double(value.translation.height)
                let step = CardReorder.step(heights: order.map { cardHeights[$0] ?? 300 }, index: index,
                                            offset: offset, spacing: cardSpacing)
                if step.index != index {
                    dragCorrection += step.offset - offset
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        model.moveCard(card, to: step.index)
                    }
                }
                dragOffset = step.offset
            }
            .onEnded { _ in
                guard draggedCard == card else { return }
                NSCursor.arrow.set()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    draggedCard = nil
                    dragOffset = 0
                }
                dragCorrection = 0
            }
    }

    private func memoryCard(_ memory: MemoryDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                cardTitle("内存去向", icon: "memorychip", color: DisplayColorRole.appMemory.color(theme: model.theme))
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle().fill(memory.pressure.color).frame(width: 7, height: 7)
                    Text(memory.pressure.title).font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(memory.pressure.color.opacity(0.10), in: Capsule())
                .help("按「还能用」占物理内存的比例：20% 以上充足，8%–20% 偏紧，不到 8% 紧张。\n"
                      + "活动监视器里的「内存压力」是系统自己的算法，看的是压缩和换出有多忙，可能跟这里不一样。"
                      + "系统现在的判断：\(memory.systemPressure.systemDescription)。")
                dragHandle(.memory)
            }
            MemorySummaryView(usedBytes: memory.usedBytes, totalBytes: memory.totalBytes > 0 ? memory.totalBytes : nil,
                              availableBytes: memory.availableBytes, theme: model.theme)
            FlowDiagram(
                sourceTitle: "物理内存", sourceSymbol: "desktopcomputer", total: memory.totalBytes > 0 ? memory.totalBytes : nil,
                items: memory.branches, unit: .memory, height: 190, gap: 22, showsSourceValue: false,
                sourceCaption: memory.totalBytes > 0 ? "\(Int((memory.totalBytes / 1_073_741_824).rounded())) GB" : nil,
                theme: model.theme, direction: model.flowDirection,
                hoverTargets: [FlowDiagram.sourceHoverID, "app", "compressed"],
                onHover: { id, inside in
                    if let target = MemoryHoverTarget(itemID: id) { model.onMemoryHover?(target, inside) }
                }
            )
            SwapUsageView(usedBytes: memory.swapUsedBytes, theme: model.theme, pressureIsNormal: memory.pressure == .normal)
            if let bandwidth = memory.bandwidth {
                MemoryBandwidthView(reading: bandwidth, theme: model.theme)
            }
        }
        .padding(14)
        .glassCard(pressureTint: memory.pressure.tint)
        .animation(.easeInOut(duration: 0.6), value: memory.pressure.tint)
    }

    private func powerCard(_ power: PowerDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                cardTitle("电力去向", icon: "bolt", color: DisplayColorRole.cpu.color(theme: model.theme))
                Spacer(minLength: 4)
                dragHandle(.power)
            }
            FlowDiagram(
                sourceTitle: "整机功率", sourceSymbol: "powerplug", total: power.totalWatts,
                items: model.displayedPowerBranches(power), unit: .power, height: 168, gap: 22, showsSourceValue: true,
                sourceValueSize: 20,
                theme: model.theme, direction: model.flowDirection
            )
            Text("整机来自 SMC 系统功率传感器，GPU 来自系统能耗计数，CPU 为相关电源轨估计；「其他」= 整机 − 已显示分项，含电源转换损耗。鼠标停在各项上可看说明。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .glassCard()
    }

    private func usageCard(_ usage: UsageReading?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                cardTitle("使用率", icon: "gauge.with.dots.needle.50percent", color: model.theme.tint)
                Spacer(minLength: 4)
                dragHandle(.usage)
            }
            UsageRowsView(usage: usage, theme: model.theme)
            Text("CPU 来自内核的核心忙碌时间，GPU 来自显卡驱动统计，磁盘和网络是两次刷新之间的平均速度；读不到的项目不显示。鼠标停在各行上可看说明。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .glassCard()
    }

    private func dragHandle(_ card: DashboardCard) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(width: 23, height: 30)
            .contentShape(Rectangle())
            .help("按住卡片任意位置上下拖，调整顺序")
            .accessibilityLabel("拖动「\(card.title)」卡片调整顺序")
            .contextMenu {
                let cards = model.visibleCards
                if let index = cards.firstIndex(of: card) {
                    Button("上移") {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.moveCard(card, to: index - 1) }
                    }
                    .disabled(index == 0)
                    Button("下移") {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.moveCard(card, to: index + 1) }
                    }
                    .disabled(index == cards.count - 1)
                    Divider()
                    Button("隐藏这张卡片") { model.setCard(card, visible: false) }
                        .disabled(!model.canHideCard(card))
                }
            }
    }

    private func cardTitle(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 25, height: 30)
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
        }
    }

    private var waitingCard: some View {
        VStack(spacing: 13) {
            Image(systemName: "leaf.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(model.theme.tint)
            Text("正在读取这台 Mac 的功耗与内存…")
                .font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .glassCard()
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("设置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let timestamp = model.snapshot?.timestamp {
                    Text(timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                        .help("最近一次采样时间")
                }
            }
            HStack(spacing: 10) {
                settingTitle("刷新")
                ForEach([1.0, 2.0, 5.0], id: \.self) { interval in
                    Button { model.setRefreshInterval(interval) } label: {
                        Text("\(Int(interval)) 秒")
                            .font(.system(size: 10, weight: model.refreshInterval == interval ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.refreshInterval == interval ? model.theme.tint.opacity(0.14) : Color.primary.opacity(0.035), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("每 \(Int(interval)) 秒刷新")
                }
                Spacer()
                Button { model.onRefresh?() } label: { Label("立即刷新", systemImage: "arrow.clockwise") }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                settingTitle("主题色")
                ForEach(DashboardTheme.allCases) { theme in
                    Button { model.setTheme(theme) } label: {
                        HStack(spacing: 4) {
                            Circle().fill(theme.tint).frame(width: 9, height: 9)
                            Text(theme.title).font(.system(size: 10))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(model.theme == theme ? theme.tint.opacity(0.14) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.title)主题")
                    .accessibilityAddTraits(model.theme == theme ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                settingTitle("方向")
                ForEach(FlowDirection.allCases) { direction in
                    Button { model.setFlowDirection(direction) } label: {
                        Text(direction.title).font(.system(size: 10))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(model.flowDirection == direction ? model.theme.tint.opacity(0.14) : Color.primary.opacity(0.035), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                settingTitle("显示卡片")
                ForEach(DashboardCard.allCases) { card in
                    let shown = !model.hiddenCards.contains(card)
                    Toggle(card.title, isOn: Binding(get: { shown }, set: { model.setCard(card, visible: $0) }))
                        .font(.system(size: 10))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .disabled(shown && !model.canHideCard(card))
                        .help(shown && !model.canHideCard(card) ? "至少留一张卡片" : "勾选的卡片显示在面板里，按住卡片可以上下拖动换位")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                settingTitle("电力分项")
                powerToggle("CPU（估计）", id: "cpu")
                powerToggle("GPU", id: "gpu")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                settingTitle("玻璃")
                Text("透明").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.glassFrost }, set: { model.setGlassFrost($0) }), in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel("玻璃效果，从透明到着色")
                Text("着色").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .help("像 iPhone 设置里的液态玻璃：往左更通透，能看清后面的桌面；往右磨砂、着色更重，字更好认。只改玻璃本身，文字和图表始终不透明。")
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("退出 WattsUp") { model.onQuit?() }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard()
    }

    private func settingTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            .frame(width: 58, alignment: .leading)
    }

    private func powerToggle(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.enabledPowerComponents.contains(id) },
            set: { model.setPowerComponent(id, enabled: $0) }
        ))
        .font(.system(size: 10))
        .toggleStyle(.checkbox)
        .fixedSize()
    }
}

/// Measured card heights, for deciding when a dragged card passes its neighbour.
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: [DashboardCard: Double] = [:]
    static func reduce(value: inout [DashboardCard: Double], nextValue: () -> [DashboardCard: Double]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The panel's glass, from clear (0) to frosted and tinted (1). On macOS 26 and
/// later it is Liquid Glass (NSGlassEffectView, clear style) with the frosted
/// HUD material faded in on top; older systems only fade the frosted material.
private struct PanelGlass: NSViewRepresentable {
    var frost: Double

    func makeNSView(context: Context) -> GlassView { GlassView() }
    func updateNSView(_ nsView: GlassView, context: Context) { nsView.frost = frost }

    final class GlassView: NSView {
        private let frosted = NSVisualEffectView()
        private var hasLiquidGlass = false
        var frost: Double = 1 { didSet { frosted.alphaValue = frostedAlpha } }

        init() {
            super.init(frame: .zero)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .clear
                glass.cornerRadius = 20
                fill(with: glass)
                hasLiquidGlass = true
            }
            frosted.material = .hudWindow
            frosted.blendingMode = .behindWindow
            frosted.state = .active
            fill(with: frosted)
            frosted.alphaValue = frostedAlpha
        }

        required init?(coder: NSCoder) { nil }

        /// Without Liquid Glass underneath, fading the material out completely
        /// would leave bare desktop, so a little frosting always stays.
        private var frostedAlpha: CGFloat { CGFloat(hasLiquidGlass ? frost : 0.3 + 0.7 * frost) }

        private func fill(with view: NSView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }
}

/// How frosted the panel glass is (0 clear … 1 tinted); cards follow it.
private struct PanelFrostKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var panelFrost: Double {
        get { self[PanelFrostKey.self] }
        set { self[PanelFrostKey.self] = newValue }
    }
}

private struct SoftIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 29, height: 29)
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0.04), in: Circle())
            .contentShape(Circle())
    }
}

private struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelFrost) private var frost
    var pressureTint: PressureTint = .none

    private var tintColor: Color {
        switch pressureTint {
        case .none: return .clear
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(.white.opacity((dark ? 0.045 : 0.36) * (0.4 + 0.6 * frost)))
                    // Memory-pressure wash: a light reminder, fading to the right.
                    shape.fill(LinearGradient(
                        colors: [tintColor.opacity(pressureTint.backgroundOpacity(darkMode: dark)),
                                 tintColor.opacity(pressureTint.trailingOpacity(darkMode: dark))],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                ZStack {
                    shape.strokeBorder(.white.opacity(dark ? 0.09 : 0.65), lineWidth: 1)
                    shape.strokeBorder(tintColor.opacity(pressureTint.borderOpacity(darkMode: dark)), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
    }
}

private extension View {
    func glassCard(pressureTint: PressureTint = .none) -> some View { modifier(GlassCard(pressureTint: pressureTint)) }
}

/// Grabbing empty header space drags the whole panel (works for borderless
/// and titled panels alike, and never steals clicks from SwiftUI buttons).
private struct WindowDragArea: NSViewRepresentable {
    var onDragBegan: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDragBegan = onDragBegan
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) { nsView.onDragBegan = onDragBegan }

    final class DragView: NSView {
        var onDragBegan: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { return }
            onDragBegan?()
            window?.performDrag(with: event)
        }
    }
}
