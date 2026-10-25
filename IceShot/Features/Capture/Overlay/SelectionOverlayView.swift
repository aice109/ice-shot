import AppKit
import SwiftUI

struct SelectionOverlayView: View {
    let frame: DisplayFrame
    let state: SelectionOverlayState
    /// 可悬停 / 点击的窗口目录（按前到后排序）；空数组表示纯框选（长截图）。
    let windows: [WindowDescriptor]
    /// 选区确定（松手）时回调一次，随后进入就地编辑。
    let onSelectionReady: (CGDirectDisplayID, CGRect) -> Void
    /// 点击高亮窗口：交给协调器抓窗口并进入就地编辑。
    let onWindowPick: (WindowDescriptor) -> Void
    let onAction: (MarkupAction) -> Void
    let onCancel: () -> Void

    @State private var interaction: Interaction = .idle
    @State private var cursorPosition: CGPoint?
    /// 指针位置的「最新值」，与 `cursorPosition` 一起去更新；
    /// 分开是因为光标重算需要「指针已经离开」这个信息，不能用 `nil` 的同义反复。
    /// 指针位置的「最新值」。
    ///
    /// 写入有两个来源：
    /// 1. 面板级的鼠标移动监视器（`CaptureOverlayPanel.onPointerMoved`，由 `state` 转进来）——
    ///    **实时**，只要指针在屏上就一定有；
    /// 2. SwiftUI 的 `onContinuousHover`——作为补充（拖拽中、刚出现时的首帧）。
    ///
    /// 只用 (2) 不够：它的追踪区跟着具体子视图走，指针停在手柄 / 工具条 / 层间空隙上时
    /// 父层收不到事件，光标就卡住不跟手。
    @State private var latestPointer: CGPoint?
    /// 操作条的实测尺寸：宽度只用于把胶囊收进屏幕，不靠常量估算。
    @State private var toolbarSize: CGSize = .zero
    @FocusState private var isFocused: Bool

    /// 操作条与屏幕边缘的最小间距。
    private static let toolbarMargin: CGFloat = 12

    private var selection: CGRect {
        state.selection(for: frame.display.id)
    }

    private var isEditing: Bool {
        state.isEditing && state.activeDisplayID == frame.display.id
    }

    private var editor: EditorModel? {
        isEditing ? state.editor : nil
    }

    /// 悬停选窗口只在「还没框选、也不在编辑」且确实有窗口目录时生效。
    private var isHoverActive: Bool {
        !windows.isEmpty && !state.isEditing && !isSelectionVisible
    }

    private var hoveredWindow: WindowDescriptor? {
        guard isHoverActive,
              state.hoveredDisplayID == frame.display.id,
              let id = state.hoveredWindowID else {
            return nil
        }
        return windows.first { $0.id == id }
    }

    private var hoverRect: CGRect? {
        guard let hoveredWindow else { return nil }
        return WindowHoverPicker.highlightRect(for: hoveredWindow, display: frame.display)
    }

    /// 整个浮层的光标**只由这里声明一次**。
    ///
    /// 以前光标散在 `selectionLayer`（十字）与 `spaceDragLayer`（抓手）两层各自 `set`，
    /// 谁后执行谁生效：框选完成后指针没移动、hover 不再回调，十字准星就留在了
    /// 「已经没有任何可绘制动作」的屏幕上；指针离开选区后抓手也没人收回。
    /// 现在按 `SelectionCursorRule` 算出唯一答案，见该文件的光标优先序。
    private var overlayCursor: PointerCursor {
        // 编辑态且选区锁定（窗口 / 全屏 / 重复区域）：整屏只剩标注画布在接收鼠标，
        // 光标由 `MarkupCanvas` 自己管，这里不表态（`declaresCursor` 会返回 false）。
        guard !isEditing || state.allowsAdjustment else {
            return .arrow
        }
        return SelectionCursorRule.cursor(for: .init(
            pointer: pointerPosition,
            selection: selection,
            isSpacePressed: state.isSpacePressed,
            isMovingSelection: isMovingSelection,
            // 只有「还没框选」时才存在点窗口即截，那时十字仍然是对的。
            isHoveringWindows: !isEditing && windows.count > 0 && !isSelectionVisible
                && state.activeDisplayID == nil,
            isCreatingSelection: isCreatingSelection,
            // 编辑态下把工具告诉规则：选中工具后选区内一律十字 / 文本 I，
            // 边缘缩放让位。无工具态传 `nil`，行为不变。
            markupTool: currentMarkupTool
        ))
    }


    /// 指针的本帧位置：优先用面板级监视器写入的实时值，没有时退回 hover 记的值。
    ///
    /// 监视器那条路是**实时**的（指针一动就更新），hover 只在拖拽中 / 首帧负责补位。
    private var pointerPosition: CGPoint? {
        state.pointer(for: frame.display.id) ?? latestPointer
    }

    /// 正在拉新框（按下未松手）。
    ///
    /// 拖到选区外是本意（拉框时指针本来就会跑在选区之外），
    /// 所以这期间不能因为「在选区外」就显示禁止光标。
    private var isCreatingSelection: Bool {
        if case .creating = interaction { return true }
        return false
    }

    /// Space 拖移中的判定：按下时已经确定开始移动选区。
    private var isMovingSelection: Bool {
        guard state.isSpacePressed else { return false }
        if case .moving = interaction { return true }
        return false
    }

    /// 本视图要不要声明光标。
    ///
    /// 编辑态且允许调范围时，选区**内部**铺着 `MarkupCanvas`，它自己会用
    /// `NSCursor.set()` 设置光标（十字 / 抓手）。两边都表态就是互相覆盖：
    /// 画布先算出抓手，外层再 apply 一次十字，最终看到的就是十字——
    /// 真机上「移到已有图形上不出抓手」就是这个原因。
    ///
    /// 分工：**选区内**归画布，**选区外（含边缘手柄）**归这里。
    private var declaresCursor: Bool {
        guard isEditing, state.allowsAdjustment else { return true }
        guard let point = pointerPosition else { return true }
        // 指针在选区内：画布在管，别抢。
        return !selection.contains(point)
    }

    /// 把工具态告诉 `SelectionCursorRule`：选中工具后，选区内一律落笔光标。
    private var currentMarkupTool: EditorTool? {
        guard isEditing, let editor else { return nil }
        return editor.tool
    }

    /// 遮罩挖洞：框选中用选区，未框选时用悬停窗口。
    private var highlightedRect: CGRect {
        isSelectionVisible ? selection : (hoverRect ?? .zero)
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.image, scale: frame.display.scale)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                DimmingOverlay(selection: highlightedRect)
                    .allowsHitTesting(false)

                if let hoveredWindow, let rect = hoverRect {
                    WindowHighlight(
                        rect: rect,
                        name: hoveredWindow.displayName,
                        bounds: proxy.size
                    )
                }

                if let editor {
                    markupCanvas(editor)
                }

                if isSelectionVisible {
                    SelectionBorder(selection: selection)
                        .allowsHitTesting(false)
                    SizeLabel(pixelSize: pixelSize)
                        .position(labelPosition(in: bounds))
                        .allowsHitTesting(false)
                }

                if isEditing {
                    if state.allowsAdjustment {
                        spaceDragLayer(bounds: bounds)
                        resizeHandles(bounds: bounds)
                    }
                } else if !state.isEditing {
                    selectionLayer(bounds: bounds)

                    if let snapshot = magnifierSnapshot,
                       let image = magnifierImage(for: snapshot) {
                        MagnifierView(image: image, snapshot: snapshot)
                            .position(magnifierPosition(in: bounds, snapshot: snapshot))
                            .allowsHitTesting(false)
                    }
                }

                if isHoverActive {
                    hoverHint(bounds: bounds)
                }

                // 按住 Space = 可以拖整个选区。提示与光标同时出现、同时消失，
                // 否则用户只知道「按住好像有用」，不知道松手就结束。
                if isEditing, state.allowsAdjustment, state.isSpacePressed {
                    spaceHint(bounds: bounds)
                }

                if let editor {
                    toolbar(bounds: bounds, editor: editor)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear {
                isFocused = true
                cursorPosition = initialCursorPosition()
                latestPointer = cursorPosition
                if let point = cursorPosition {
                    updateHover(at: point)
                }
            }
            .onChange(of: state.activeDisplayID) { _, newValue in
                if newValue != frame.display.id {
                    interaction = .idle
                    cursorPosition = nil
                    latestPointer = nil
                }
            }
            .onKeyPress { press in
                switch press.key {
                case .escape:
                    // Esc 的唯一拥有者是 `SelectionOverlayController` 的面板级监听（状态最全，
                    // 也负责收尾）。这里**刻意什么都不做**：实测 SwiftUI 这个 handler 会在监听
                    // 已经退出取字模式之后才被调用，那时状态看起来「没有模式」，再判一次就把
                    // 整次截图关掉了。放行下去还有 `CaptureOverlayPanel.cancelOperation` 兜底。
                    EscapeTrace.log("view.onKeyPress", "ignored editing=\(isEditing)")
                    return .ignored
                case .leftArrow, .rightArrow, .upArrow, .downArrow:
                    guard !isEditing || state.allowsAdjustment else {
                        return .ignored
                    }
                    handleArrow(press, bounds: bounds)
                    return .handled
                case .return:
                    // 未框选时 Return 确认光标下的窗口，与窗口选择模式一致。
                    guard isHoverActive, let window = windowUnderCursor else {
                        return .ignored
                    }
                    state.clear(displayID: frame.display.id)
                    onWindowPick(window)
                    return .handled
                default:
                    return .ignored
                }
            }
            // 光标只在这里声明一次。`onContinuousHover` 只在指针移动时回调，所以
            // 框选完成、选区被清空、Space 状态变化都会经由 `latestPointer` / 状态变化
            // 触发重算——否则指针不动的时候，十字或抓手会永远留在屏幕上。
            .pointerCursorIfPresent(declaresCursor ? overlayCursor : nil)

        }
    }

    /// 就地面布：区域截图用整帧作为模型图，按选区裁窗显示；
    /// 预设选区（窗口 / 全屏 / 重复区域）直接用选区矩形。
    ///
    /// 交互范围即选区本身：图外按下不应开始绘制。
    private func markupCanvas(_ model: EditorModel) -> some View {
        let imageFrame = state.editorImageFrame
        let offsetX = selection.minX - imageFrame.minX
        let offsetY = selection.minY - imageFrame.minY
        return ZStack(alignment: .topLeading) {
            MarkupCanvas(
                model: model,
                padding: 0,
                showsBackground: false,
                interactionRect: CGRect(
                    x: selection.minX - imageFrame.minX,
                    y: selection.minY - imageFrame.minY,
                    width: selection.width,
                    height: selection.height
                ),
                // 图外（选区外）= 禁止：那里既不能画也不能选，按下没有结果。
                // 选区边缘要留给缩放手柄，否则指针贴到手柄上还是禁止，看不出能缩放。
                outerCursor: { point in
                    SelectionCursorRule.axis(at: point, selection: selection) == nil
                        ? .notAllowed
                        : nil
                },
                onQuickCopy: { onAction(.copy) },
                // Space 状态必须传给画布：它是选区内真正碰光标的那一层，
                // 不告诉它，外层算好的抓手会被它盖成箭头（真机上就是这个现象）。
                isSpacePressed: state.isSpacePressed
            )
            .frame(width: imageFrame.width, height: imageFrame.height)
            .offset(x: -offsetX, y: -offsetY)
        }
        .frame(width: selection.width, height: selection.height, alignment: .topLeading)
        .clipped()
        .position(x: selection.midX, y: selection.midY)
    }

    private var isSelectionVisible: Bool {
        selection.width > 0 && selection.height > 0
    }

    private var pixelSize: CGSize {
        ScreenGeometry.pixelRect(fromDisplayLocal: selection, scale: frame.display.scale).size
    }

    /// 选区阶段：整屏接收拖拽，框出新选区；短位移则当作点击（截高亮窗口）。
    private func selectionLayer(bounds: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(selectionGesture(bounds: bounds))
            // 只负责「指针在哪」：光标由外层 `overlayCursor` 统一声明。
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    cursorPosition = location
                    latestPointer = location
                    updateHover(at: location)
                case .ended:
                    cursorPosition = nil
                    latestPointer = nil
                    state.clearHover(displayID: frame.display.id)
                }
            }
    }

    /// 编辑阶段：只在按住 Space 时接管拖拽，用于平移选区。
    private func spaceDragLayer(bounds: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(state.isSpacePressed)
            .gesture(selectionGesture(bounds: bounds))
            // 按住 Space 且指针在选区内 = 可以整块拖走选区；按下后变抓紧。
            // 光标同样交给外层 `overlayCursor`，这里只记录指针位置。
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    cursorPosition = location
                    latestPointer = location
                case .ended:
                    latestPointer = nil
                }
            }
    }

    private func resizeHandles(bounds: CGRect) -> some View {
        ForEach(ResizeHandle.allCases) { handle in
            ResizeHandleView(
                handle: handle,
                selection: selection,
                onChanged: { raw in
                    state.update(
                        displayID: frame.display.id,
                        rect: snapped(
                            ScreenGeometry.clamped(raw, to: bounds),
                            bounds: bounds
                        )
                    )
                }
            )
        }
    }

    private func selectionGesture(bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                cursorPosition = value.location
                latestPointer = value.location
                if case .idle = interaction {
                    beginInteraction(at: value.startLocation)
                }
                updateInteraction(
                    current: value.location,
                    bounds: bounds
                )
            }
            .onEnded { value in
                cursorPosition = value.location
                latestPointer = value.location
                // 松手后把指针位置刷成监视器看到的最新值：
                // 框选完成这一帧指针可能已经继续移动过，用拖拽值会差一点点，
                // 而那时正好是「从十字切到箭头 / 禁止」的一格。
                if let current = state.pointer(for: frame.display.id) {
                    latestPointer = current
                }
                var didPickWindow = false
                if case .creating = interaction {
                    // 已经拉出可截取选区时，即使起止位移很小也算框选完成：
                    // 小目标（通知横幅、图标）的框本来就小，不能被当成点击吞掉。
                    let kind = PointerInteraction.kind(
                        translation: value.translation,
                        selectionSize: selection.size
                    )
                    if kind == .click {
                        didPickWindow = handleClick(at: value.location)
                    }
                    // 点击没命中窗口时选区已经被清掉：这时不能停在原地
                    // （否则用户看到的是“点了没反应”），改为保持浮层等待下一次操作。
                    if kind == .click, !didPickWindow {
                        interaction = .idle
                        return
                    }
                } else if !isSelectionVisible {
                    state.clear(displayID: frame.display.id)
                }
                interaction = .idle

                guard !didPickWindow else { return }
                if !isEditing, isSelectionVisible {
                    onSelectionReady(frame.display.id, selection)
                }
            }
    }

    /// 点击：命中窗口就交给协调器抓窗口，否则按原行为清空抖出的亚像素选区。
    private func handleClick(at point: CGPoint) -> Bool {
        state.clear(displayID: frame.display.id)
        let hit = WindowHoverPicker.window(
            atLocalPoint: point,
            display: frame.display,
            windows: windows
        )
        guard let hit else {
            return false
        }
        onWindowPick(hit)
        return true
    }

    private func updateHover(at point: CGPoint) {
        guard isHoverActive else { return }
        let window = WindowHoverPicker.window(
            atLocalPoint: point,
            display: frame.display,
            windows: windows
        )
        state.updateHover(windowID: window?.id, displayID: frame.display.id)
    }

    /// 光标下的窗口（Return 确认用）：优先取悬停状态，避免连续悬停事件之间的空档。
    private var windowUnderCursor: WindowDescriptor? {
        if let hoveredWindow {
            return hoveredWindow
        }
        guard let cursorPosition else { return nil }
        return WindowHoverPicker.window(
            atLocalPoint: cursorPosition,
            display: frame.display,
            windows: windows
        )
    }

    private func beginInteraction(at point: CGPoint) {
        if state.isEditing {
            guard isEditing else {
                // 编辑期间其他显示器的浮层不再接受新的框选。
                interaction = .idle
                return
            }
            guard state.allowsAdjustment,
                  state.isSpacePressed,
                  isSelectionVisible,
                  selection.insetBy(dx: -1, dy: -1).contains(point) else {
                interaction = .idle
                return
            }
            interaction = .moving(startRect: selection, startPoint: point)
            return
        }

        if state.activeDisplayID != frame.display.id {
            state.update(displayID: frame.display.id, rect: .zero)
        }
        interaction = .creating(anchor: point)
    }

    private func updateInteraction(current: CGPoint, bounds: CGRect) {
        switch interaction {
        case .idle:
            break
        case .creating(let anchor):
            let raw = SelectionGeometry.rect(
                from: anchor,
                to: current,
                lockAspect: NSEvent.modifierFlags.contains(.shift),
                fromCenter: NSEvent.modifierFlags.contains(.option)
            )
            state.update(
                displayID: frame.display.id,
                rect: snapped(ScreenGeometry.clamped(raw, to: bounds), bounds: bounds)
            )
        case .moving(let startRect, let startPoint):
            let raw = startRect.offsetBy(
                dx: current.x - startPoint.x,
                dy: current.y - startPoint.y
            )
            state.update(
                displayID: frame.display.id,
                rect: snapped(ScreenGeometry.clamped(raw, to: bounds), bounds: bounds)
            )
        }
    }

    private func handleArrow(_ press: KeyPress, bounds: CGRect) {
        guard isSelectionVisible else { return }
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        let dx: CGFloat
        let dy: CGFloat
        switch press.key {
        case .leftArrow:
            dx = -step
            dy = 0
        case .rightArrow:
            dx = step
            dy = 0
        case .upArrow:
            dx = 0
            dy = -step
        case .downArrow:
            dx = 0
            dy = step
        default:
            return
        }
        let moved = selection.offsetBy(dx: dx, dy: dy)
        state.update(
            displayID: frame.display.id,
            rect: snapped(ScreenGeometry.clamped(moved, to: bounds), bounds: bounds)
        )
    }

    private func snapped(_ rect: CGRect, bounds: CGRect) -> CGRect {
        let snapped = ScreenGeometry.snapRect(rect, scale: frame.display.scale)
        return ScreenGeometry.clamped(snapped, to: bounds)
    }

    private var magnifierSnapshot: MagnifierSnapshot? {
        guard isSelectionVisible, let cursorPosition else {
            return nil
        }
        return MagnifierGeometry.snapshot(
            imagePixelSize: CGSize(
                width: frame.image.width,
                height: frame.image.height
            ),
            cursorLocalPoint: cursorPosition,
            displayScale: frame.display.scale
        )
    }

    private func magnifierImage(for snapshot: MagnifierSnapshot) -> CGImage? {
        frame.image.cropping(to: snapshot.pixelRect)
    }

    private func magnifierPosition(
        in bounds: CGRect,
        snapshot: MagnifierSnapshot
    ) -> CGPoint {
        let contentSize = CGSize(
            width: CGFloat(snapshot.columns) * snapshot.cellSize,
            height: CGFloat(snapshot.rows) * snapshot.cellSize
        )
        let size = CGSize(
            width: contentSize.width + 12,
            height: contentSize.height + 36
        )
        let cursor = cursorPosition ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let gap: CGFloat = 20
        let margin: CGFloat = 8

        var x = cursor.x + gap
        if x + size.width > bounds.maxX - margin {
            x = cursor.x - gap - size.width
        }
        x = min(max(x, margin), max(margin, bounds.maxX - size.width - margin))

        var y = cursor.y + gap
        if y + size.height > bounds.maxY - margin {
            y = cursor.y - gap - size.height
        }
        y = min(max(y, margin), max(margin, bounds.maxY - size.height - margin))

        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }

    private func initialCursorPosition() -> CGPoint? {
        OverlayCoordinates.viewPoint(
            fromScreen: NSEvent.mouseLocation,
            displayFrame: frame.display.appKitFrame
        )
    }

    private func labelPosition(in bounds: CGRect) -> CGPoint {
        let x = min(max(selection.minX, 46), max(46, bounds.maxX - 46))
        let y = selection.minY >= 24 ? selection.minY - 14 : selection.minY + 14
        return CGPoint(x: x, y: y)
    }

    private func toolbarPosition(in bounds: CGRect) -> CGPoint {
        // 宽度取实测值：首帧还没量到就按 0 处理（无横向约束），下一帧再收进屏幕；
        // 用常量估算的话，工具增减、系统字号变化都会让估算失效。
        let half = min(toolbarSize.width / 2, max(0, bounds.width / 2 - Self.toolbarMargin))
        let x = min(max(selection.midX, half), max(half, bounds.maxX - half))
        let below = selection.maxY + 30
        let y = below + 24 <= bounds.maxY ? below : max(24, selection.minY - 30)
        return CGPoint(x: x, y: y)
    }

    private func hoverHint(bounds: CGRect) -> some View {
        VStack {
            Spacer()
            Text("点击窗口截图 · 拖拽框选区域 · Esc 取消")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassSurface(contrast: .elevated, in: Capsule())
                .padding(.bottom, 24)
        }
        .frame(maxWidth: bounds.width)
        .allowsHitTesting(false)
    }

    /// 按住 Space 时的浮层提示：告诉用户「松手就停」。
    ///
    /// 只在编辑态、允许调范围、且真的按住 Space 时出现；
    /// 一松手 `isSpacePressed` 变 false，提示随之消失。
    private func spaceHint(bounds: CGRect) -> some View {
        VStack {
            Spacer()
            Text("按住 Space 可拖动选区 · 松开结束")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassSurface(contrast: .elevated, in: Capsule())
                .padding(.bottom, 24)
        }
        .frame(maxWidth: bounds.width)
        .allowsHitTesting(false)
    }

    private func toolbar(bounds: CGRect, editor: EditorModel) -> some View {
        MarkupToolbar(
            model: editor,
            context: .overlay,
            actions: MarkupActions(
                copy: { onAction(.copy) },
                save: { onAction(.save) },
                pin: { onAction(.pin) },
                close: { onAction(.close) }
            ),
            // 就地浮层的选区本身就是裁剪范围，再裁一次会让选区与图像坐标错位。
            showsCropTool: false
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { toolbarSize = $0 }
        .position(toolbarPosition(in: bounds))
    }
}

private enum Interaction {
    case idle
    case creating(anchor: CGPoint)
    case moving(startRect: CGRect, startPoint: CGPoint)
}

/// 选区手柄：拖动时按 `SelectionGeometry` 计算新矩形，由父视图裁剪与像素对齐。
///
/// 光标由 `PointerCursor` 统一给出：悬停 = 该方向的缩放箭头，拖动中 = 同一箭头。
/// 以前这里完全没有光标提示，用户悬停到手柄上看到的还是箭头，根本不知道能拖。
private struct ResizeHandleView: View {
    let handle: ResizeHandle
    let selection: CGRect
    /// 拖拽过程中回调原始矩形（未裁剪）。
    let onChanged: (CGRect) -> Void
    @State private var startRect: CGRect?
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 1)
            }
            .frame(width: 10, height: 10)
            .contentShape(Circle())
            .position(handle.position(in: selection))
            .onHover { isHovering = $0 }
            .pointerCursor(isHovering || isDragging ? .resizing(handle.axis) : .arrow)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let start = startRect ?? selection
                        if startRect == nil {
                            startRect = start
                        }
                        let origin = handle.position(in: start)
                        let point = CGPoint(
                            x: origin.x + value.translation.width,
                            y: origin.y + value.translation.height
                        )
                        onChanged(
                            SelectionGeometry.resized(
                                rect: start,
                                handle: handle,
                                to: point,
                                lockAspect: NSEvent.modifierFlags.contains(.shift)
                            )
                        )
                    }
                    .onEnded { _ in
                        startRect = nil
                        isDragging = false
                    }
            )
            .accessibilityLabel("调整选区")
    }
}

private struct SelectionBorder: View {
    let selection: CGRect

    var body: some View {
        Path { path in
            path.addRect(selection)
        }
        .stroke(Color.accentColor, lineWidth: 1)
    }
}

private struct SizeLabel: View {
    let pixelSize: CGSize

    var body: some View {
        Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassSurface(contrast: .elevated, in: Capsule())
    }
}

