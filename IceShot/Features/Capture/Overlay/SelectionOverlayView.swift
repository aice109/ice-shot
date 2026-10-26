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
    @FocusState private var isFocused: Bool

    /// 操作条与屏幕边缘的最小间距。
    private static let toolbarMargin: CGFloat = 12
    /// 浮层内部统一坐标系：操作条形与指针位置都在这个空间里比较。
    private static let overlaySpace = "captureOverlay"

    /// 操作条与选区边框之间的固定间隙。
    ///
    /// 必须大于 `SelectionCursorRule.edgeTolerance`（4 pt），否则工具条边缘会被算进
    /// 边框缩放带；也要留得出手柄（10 pt 圆）的位置，否则下边框拖不动。
    private static let toolbarGap: CGFloat = 14

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
    private func overlayCursor(in bounds: CGRect) -> PointerCursor {
        // 编辑态且选区锁定（窗口 / 全屏 / 重复区域）：选区调不动，光标没有可表达的东西。
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
            isOverAnnotation: isOverAnnotation,
            isMovingAnnotation: isMovingAnnotation,
            isOverToolbar: isOverToolbar(in: bounds),
            // 编辑态下把工具告诉规则：选中工具后选区内一律十字 / 文本 I。
            markupTool: currentMarkupTool
        ))
    }

    /// 指针是否落在操作条上（含两个胶囊之间的透明间隙）。
    ///
    /// 操作条是两个玻璃胶囊并排，中间那 10 pt 是透明的——视觉上「指针在界面上」，
    /// 但两个胶囊的 `contentShape` 都不含它，只按胶囊判定就会漏。
    ///
    /// 矩形由「`toolbarPosition` 算出的中心点 + 实测尺寸」拼出：中心点与 `.position(...)`
    /// 用的是**同一个函数**，两者不会各说各话。不用 `frame(in: .named(...))`——
    /// 那条路在命名坐标空间没解析出来时会静默给 `.zero`，判定于是全 false，
    /// 表现就是「工具条上穿过去仍是缩放，移出去才恢复」。
    private func isOverToolbar(in bounds: CGRect) -> Bool {
        guard isEditing, toolbarSize.width > 0, toolbarSize.height > 0 else { return false }
        guard let point = pointerPosition else { return false }
        let center = toolbarPosition(in: bounds)
        let rect = CGRect(
            x: center.x - toolbarSize.width / 2,
            y: center.y - toolbarSize.height / 2,
            width: toolbarSize.width,
            height: toolbarSize.height
        ).insetBy(dx: -2, dy: -2)
        return rect.contains(point)
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

    /// 画布是否正在拖动一条已有标注（由画布自己上报）。
    @State private var isMovingAnnotation = false
    /// 操作条的实测尺寸（含两胶囊之间的透明间隙）。
    @State private var toolbarSize: CGSize = .zero

    /// 指针是否落在**已有标注的实际可修改区域**上。
    ///
    /// 规则本身在 `EditorAnnotation.hitTest`（矩形只算描边、不算中间空白）；
    /// 这里只负责把浮层坐标换算成原图像素再问一次。
    private var isOverAnnotation: Bool {
        guard isEditing, let editor, let point = pointerPosition else { return false }
        let imageFrame = state.editorImageFrame
        guard imageFrame.width > 0, imageFrame.height > 0 else { return false }
        // **复用画布自己那套布局**，不另写一遍换算。
        // 手写 scaleX/scaleY 只有在宽高比恰好匹配、且 origin 为零时才与画布一致；
        // 一旦不匹配（多屏缩放比、非整数 scale），拾取位置就整体漂移，
        // 表现为「明明在矩形边框上却没有抓手」。
        let layout = EditorCanvasLayout(
            imageSize: CGSize(width: editor.image.width, height: editor.image.height),
            viewSize: imageFrame.size,
            padding: 0
        )
        let viewPoint = CGPoint(x: point.x - imageFrame.minX, y: point.y - imageFrame.minY)
        guard layout.imageRect.contains(viewPoint) else { return false }
        let pixel = layout.imagePoint(viewPoint)
        // 容差按当前缩放换算成屏幕约 7 pt，缩小时也不会「点不中」。
        let tolerance = 7 / max(layout.scale, 0.01)
        return editor.annotations.reversed().contains { $0.hitTest(pixel, tolerance: tolerance) }
    }

    /// 把工具态告诉 `SelectionCursorRule`：选中工具后，选区内一律落笔光标。
    ///
    /// 取字模式（系统 Live Text 选取图中文字）借用 `.text`：那一格的语义就是「这里能选字」，
    /// 光标自然该是文本 I，不必在规则里再加一个并列分支。
    private var currentMarkupTool: EditorTool? {
        guard isEditing, let editor else { return nil }
        return editor.isTextPicking ? .text : editor.tool
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
            .coordinateSpace(.named(Self.overlaySpace))
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
            //
            // 光标只在这里声明一次：`SelectionCursorRule` 是唯一算家，
            // 覆盖操作条 / 暗区 / 边框 / 绘制区域 / 截图区域全部情况。
            // 画布以 `managesCursor: false` 让出，不再各写一套全局 `NSCursor.set()`。
            .pointerCursor(overlayCursor(in: bounds))

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
                onQuickCopy: { onAction(.copy) },
                // Space 状态必须传给画布：它是选区内真正碰光标的那一层，
                // 不告诉它，外层算好的抓手会被它盖成箭头（真机上就是这个现象）。
                isSpacePressed: state.isSpacePressed,
                // 光标由本视图外层独占（`SelectionCursorRule` 能同时看到选区 / 边框 /
                // 暗区 / 操作条，画布只看得到图）。画布若也写全局光标就会互相覆盖。
                managesCursor: false,
                onMovingAnnotationChange: { isMovingAnnotation = $0 }
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

    /// 选区缩放手柄。
    ///
    /// **命中区必须与光标提示一致**：`SelectionCursorRule` 在整个边带（含内侧几 pt）
    /// 都显示缩放箭头，所以那一整条边都得能拖。以前只有 8 个 10 pt 圆点能拖，
    /// 光标却在一整圈上提示「可以拉」——视觉承诺与实际行动对不上，
    /// 真机手感就是「只有几个点能拉，还不灵敏」。
    ///
    /// 分两层：
    /// - **命中层**：四条边各一个整边长的透明条，四角各一个小方块；角后声明、盖在边上面，
    ///   于是角优先命中（与光标判定「角优先于边」一致）。
    /// - **视觉层**：8 个白色圆点，`allowsHitTesting(false)`，只负责显示。
    private func resizeHandles(bounds: CGRect) -> some View {
        let corners = ResizeHandle.allCases.filter { $0.axis.isCorner }
        let edges = ResizeHandle.allCases.filter { !$0.axis.isCorner }
        return ZStack {
            ForEach(edges) { handle in
                ResizeHandleHitArea(
                    handle: handle,
                    selection: selection,
                    onChanged: { raw in
                        state.update(
                            displayID: frame.display.id,
                            rect: snapped(ScreenGeometry.clamped(raw, to: bounds), bounds: bounds)
                        )
                    }
                )
            }
            ForEach(corners) { handle in
                ResizeHandleHitArea(
                    handle: handle,
                    selection: selection,
                    onChanged: { raw in
                        state.update(
                            displayID: frame.display.id,
                            rect: snapped(ScreenGeometry.clamped(raw, to: bounds), bounds: bounds)
                        )
                    }
                )
            }
            ForEach(ResizeHandle.allCases) { handle in
                ResizeHandleDot(handle: handle, selection: selection)
                    .allowsHitTesting(false)
            }
        }
        // 按住 Space = 明确要拖整个选区。命中层在 `spaceDragLayer` 之上，
        // 不让位的话「光标显示抓手、按下去却在拉边框」，与光标判定打架。
        .allowsHitTesting(!state.isSpacePressed)
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
        let size = toolbarSize
        let half = min(size.width / 2, max(0, bounds.width / 2 - Self.toolbarMargin))
        let x = min(max(selection.midX, half), max(half, bounds.maxX - half))

        // 纵向偏移必须按**工具栏实际高度**算，不能用固定值当中心偏移。
        // 用固定 30 时，工具条高约 50+，上边缘就落在选区下边框附近：
        //   1. 盖住下边框的缩放手柄 → 底部边框拖不动；
        //   2. 与下边框之间只剩一条几 pt 的缝 → 指针在那儿既不算在工具条上
        //      （`isOverToolbar` 判不到），又落进 `axis()` 的容差带 → 冒出一圈缩放图标。
        // 现在保证工具条与选区之间恒定留出 `toolbarGap`，两者永不重叠。
        // `toolbarSize` 首帧还是 `.zero`，此时拿它算偏移会把工具条直接压在选区下边框上
        // （手柄被盖、边框拖不动）。用一个保守下限兜住首帧。
        let halfHeight = max(size.height, 44) / 2
        let below = selection.maxY + Self.toolbarGap + halfHeight
        let above = selection.minY - Self.toolbarGap - halfHeight
        let y: CGFloat
        if below + halfHeight <= bounds.maxY {
            y = below
        } else if above - halfHeight >= 0 {
            y = above
        } else {
            // 上下都放不下（选区几乎占满屏幕）：夹在屏内，至少不跑到屏幕外。
            y = min(max(below, halfHeight), max(halfHeight, bounds.maxY - halfHeight))
        }
        return CGPoint(x: x, y: y)
    }

    private func hoverHint(bounds: CGRect) -> some View {
        VStack {
            Spacer()
            Text("点击窗口截图 · 拖拽框选区域 · 右键 / Esc 取消")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassSurface(.clear, contrast: .none, in: Capsule())
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
                .glassSurface(.clear, contrast: .none, in: Capsule())
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
        // 只测**尺寸**（相对测量，不依赖任何坐标空间），位置仍由 `toolbarPosition` 决定。
        // 用 `GeometryReader` + `onAppear`/`onChange` 双保险：`onGeometryChange` 在某些
        // 布局下首帧不触发，尺寸留 0 会让命中判定整个失效。
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { toolbarSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in toolbarSize = size }
            }
        )
        .position(toolbarPosition(in: bounds))
    }
}

private enum Interaction {
    case idle
    case creating(anchor: CGPoint)
    case moving(startRect: CGRect, startPoint: CGPoint)
}

/// 手柄的**视觉**圆点。只显示，不接收事件（命中由 `ResizeHandleHitArea` 负责）。
private struct ResizeHandleDot: View {
    let handle: ResizeHandle
    let selection: CGRect

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay {
                Circle().stroke(Color.accentColor, lineWidth: 1)
            }
            .frame(width: 10, height: 10)
            .position(handle.position(in: selection))
            .accessibilityHidden(true)
    }
}

/// 手柄的**命中区**：整条边 / 整个角方块都能开始拖。
///
/// 尺寸与 `SelectionCursorRule` 的判定对齐——那里用 `edgeTolerance` 当角半径、
/// `edgeBand` 当边带宽，这里用同一个半宽铺矩形，所以「显示缩放的地方」和
/// 「能拖的地方」是同一块区域。
private struct ResizeHandleHitArea: View {
    let handle: ResizeHandle
    let selection: CGRect
    let onChanged: (CGRect) -> Void

    @State private var startRect: CGRect?

    private var hitRect: CGRect {
        let half = SelectionCursorRule.edgeTolerance
        switch handle {
        case .topLeft:
            return CGRect(x: selection.minX - half, y: selection.minY - half,
                          width: half * 2, height: half * 2)
        case .topRight:
            return CGRect(x: selection.maxX - half, y: selection.minY - half,
                          width: half * 2, height: half * 2)
        case .bottomLeft:
            return CGRect(x: selection.minX - half, y: selection.maxY - half,
                          width: half * 2, height: half * 2)
        case .bottomRight:
            return CGRect(x: selection.maxX - half, y: selection.maxY - half,
                          width: half * 2, height: half * 2)
        case .top:
            // 整条边都算，两端交给上层的角手柄（角优先）。
            return CGRect(x: selection.minX, y: selection.minY - half,
                          width: max(selection.width, half * 2), height: half * 2)
        case .bottom:
            return CGRect(x: selection.minX, y: selection.maxY - half,
                          width: max(selection.width, half * 2), height: half * 2)
        case .left:
            return CGRect(x: selection.minX - half, y: selection.minY,
                          width: half * 2, height: max(selection.height, half * 2))
        case .right:
            return CGRect(x: selection.maxX - half, y: selection.minY,
                          width: half * 2, height: max(selection.height, half * 2))
        }
    }

    var body: some View {
        let rect = hitRect
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
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
            .glassSurface(.clear, contrast: .none, in: Capsule())
    }
}

