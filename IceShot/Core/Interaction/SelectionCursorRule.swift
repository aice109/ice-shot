import CoreGraphics

/// 浮层**选区阶段**（还没进就地标注）该显示什么光标的唯一判定。
///
/// 为什么不放在视图的 if/else 里：这段光标被两个互不通信的来源驱动——
/// 指针位置（`onContinuousHover`，由 `selectionLayer` 提供）和按键状态（Space，
/// 由 `spaceDragLayer` 提供）。以前两边都直接改全局光标，谁后 `set` 谁赢：
/// - 指针停在选区里叠着两层，离开选区后没人再算，光标就停在最后一个值上；
/// - 框选完成后指针可能一直没动，`onContinuousHover` 不会再回调，十字准星就留在了
///   「已经没有任何可绘制动作」的屏幕上。
///
/// 现在只在这里算一次「此刻应该显示什么」，视图每帧用 `.pointerCursor(_:)` 声明。
/// 纯输入输出，不依赖 AppKit，可直接单测。
enum SelectionCursorRule {
    /// 判定需要的全部输入。
    struct Input: Equatable {
        /// 指针在所在显示器局部坐标里的位置；`nil` 表示指针不在这块屏幕上。
        var pointer: CGPoint?
        /// 有选区的显示器局部矩形；`.zero` 表示还没框选。
        var selection: CGRect
        /// 正在按住 Space。
        var isSpacePressed: Bool
        /// 正在拖移选区（Space + 拖动中）。
        var isMovingSelection: Bool
        /// 还没框选、可以「点窗口即截」。
        var isHoveringWindows: Bool
        /// 正在拉新选区（按下未松手）。拖拽期间指针跑出选区是本意，不能报「无效」。
        var isCreatingSelection: Bool
        /// 指针是否落在**已有标注的实际可修改区域**上（矩形只算描边、不算中间空白）。
        /// 命中即抓手：任何工具下都能直接拖走旧标注。
        var isOverAnnotation: Bool = false
        /// 正在拖动已有标注（按下未松手）。
        var isMovingAnnotation: Bool = false
        /// 指针落在操作条（含其弹出的浮窗）上。
        ///
        /// 操作条是压在暗区上的**界面控件**，不是画布的一部分——指针在上面时永远是
        /// 正常箭头，不能因为「它在选区外」就报禁止，也不能因为它压着边框就报缩放。
        var isOverToolbar: Bool = false
        /// 当前选中的标注工具（`nil` = 编辑态但没传工具信息）。
        ///
        /// 决定「选区内」的口径：绘制类 = 落笔光标，选择态 = 箭头，
        /// 两者都不再抡成边缘缩放箭头。
        var markupTool: EditorTool?
    }

    /// 角与边**中点**的命中半径。手柄圆圈半径是 5，命中区取 6 比它略大一点。
    static let edgeTolerance: CGFloat = 6

    /// 边带宽度：**整条边**都能拉，不只是中点那一点。
    ///
    /// 以前这里复用 `edgeTolerance`（4）当 `edgeWidth`，而 `ResizeHitZone` 内部算的是
    /// 半宽 `edgeWidth / 2` —— 于是边带只有 **2 pt**。指针几乎不可能精准停在 2 pt 内，
    /// 真机上就是「四角能拉、四条边拉不动」。边带必须按「带宽」而不是「半宽」给值。
    ///
    /// 12 是权衡：够宽到随手能命中，又小于 `toolbarGap`（14），不会和操作条抢地方。
    static let edgeBand: CGFloat = 12

    /// 给出应该显示的光标。**纯区域判定，指针在哪一格就按那一格的规则。**
    ///
    /// 区域与优先级（从高到低，第一条命中就停）：
    ///
    /// | 区域 | 光标 |
    /// | --- | --- |
    /// | 手势中（拖标注 / 拖选区 / 拉新框） | 锁死，不随区域变 |
    /// | 操作条（含浮窗） | 正常箭头 |
    /// | 暗区（选区外） | 禁止 |
    /// | 边框（四边含四角） | 该方向缩放 |
    /// | 绘制区域（标注实际画到的范围） | 抓手 / 抓紧 |
    /// | 截图区域 | 选择态箭头 · 文本 I · 其余十字 |
    ///
    /// 手势态排在最前：拖拽期间指针会跨过多个区域，按区域算会一路跳变，
    /// 所以按下到松手之间光标锁死，松手后重新按区域算。
    static func cursor(for input: Input) -> PointerCursor {
        // ── 手势中：锁死 ──
        if input.isMovingSelection {
            return .closedHand
        }
        if input.isMovingAnnotation {
            return .closedHand
        }
        // 拉框拖到选区外是本意，不能报禁止。指针为 `nil`（不在这块屏上）时除外——
        // 那说明本帧根本没有指针数据，交给后面的通用分支给箭头最安全。
        if input.isCreatingSelection, input.pointer != nil {
            return .crosshair
        }

        // ── 操作条：界面控件，永远正常箭头 ──
        if input.isOverToolbar {
            return .arrow
        }

        // ── 还没框选：整屏的动作就是拉新框 / 点窗口 ──
        guard input.selection.width > 0, input.selection.height > 0 else {
            return input.isHoveringWindows || input.pointer != nil ? .crosshair : .arrow
        }
        guard let point = input.pointer else {
            return .arrow
        }

        // ── 按住 Space = 明确要拖整个选区，选区内一律抓手 ──
        if input.isSpacePressed, containsInclusive(input.selection, point) {
            return .openHand
        }

        // ── 边框（四边含四角）：调选区大小的专用地带，与当前工具无关 ──
        //
        // **先于暗区判定**：`CGRect.contains` 是半开区间，落在 `maxX` / `maxY` 上的点
        // 会被判成「在选区外」，先判暗区就把整条右边、下边和四个角的缩放吃掉了。
        // 边界带本来就是跨边界的（内外侧几 pt 都算），它盖住那一圈才是对的。
        if let axis = axis(at: point, selection: input.selection) {
            return .resizing(axis)
        }

        // ── 暗区：框已定，选区外按下没有任何结果 ──
        guard containsInclusive(input.selection, point) else {
            return .notAllowed
        }

        // ── 绘制区域：标注实际画到的地方（矩形只算描边，不算中间空白）──
        if input.isOverAnnotation {
            // 文字工具点在已有文字上 = 进编辑，与双击同一去向，光标得说同一句话。
            return input.markupTool == .text ? .iBeam : .openHand
        }

        // ── 截图区域 ──
        switch input.markupTool {
        case .text:
            return .iBeam
        case .select, .none:
            return .arrow
        default:
            return .crosshair
        }
    }

    /// 闭区间包含判定。
    ///
    /// 不能直接用 `CGRect.contains`：它是**半开**的（含 minX/minY、不含 maxX/maxY），
    /// 于是选区的右边、下边整条线都会被判成「在选区外」。
    /// 光标判定里这一格尤其致命——那条线上本该是缩放箭头。
    static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// 指针是否贴在选区边缘（含角）。也用于「按下时要不要开始缩放」。
    static func axis(
        at point: CGPoint,
        selection: CGRect,
        tolerance: CGFloat = edgeTolerance,
        band: CGFloat = edgeBand
    ) -> ResizeAxis? {
        ResizeHitZone.axis(
            at: point,
            in: selection,
            radius: tolerance,
            edgeWidth: band
        )
    }
}
