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
        /// 当前选中的标注工具（`nil` = 无工具态）。
        ///
        /// 只影响「选区内」的口径：工具亮着时鼠标语义是「落笔」，
        /// 边缘不应再抡成缩放箭头；图外 / 图幅边缘与无工具态一致。
        var markupTool: EditorTool?
    }

    /// 缩放手柄的命中半径：按到像素边缘的距离算。
    ///
    /// 取 4：手柄圆圈半径 5，命中比它略大一点，手不用瞄准到像素级，但也不会让
    /// 整条边都变成「缩放区」——只有真正贴着边缘才换缩放箭头。
    static let edgeTolerance: CGFloat = 4

    /// 给出应该显示的光标。
    ///
    /// 优先序（从高到低）：
    /// 1. 拖移选区中：抓紧（松手前不变，否则中途会跳一下）。
    /// 2. 还没框选：十字——这一阶段整屏的动作就是拉新选区 / 点窗口。
    /// 3. 正在拉框：十字，指针拖到选区外也照旧（那是本意，不是无效操作）。
    /// 4. 指针不在本屏：箭头。
    /// 5. 贴在选区某条边 / 某个角上：该方向的缩放箭头（角优先于边）。
    /// 6. 选区内 + 按住 Space：可抓取的抓手。
    /// 7. 选区内、其余情况：箭头——那里没有任何动作。
    /// 8. **选区外：禁止**——框已经定了，此时在选区外按下不会产生任何结果，
    ///    用系统的「不可操作」光标把这件事说清楚（对齐微信截图）。
    static func cursor(for input: Input) -> PointerCursor {
        if input.isMovingSelection {
            return .closedHand
        }
        guard input.selection.width > 0, input.selection.height > 0 else {
            // 没框选：要么在拉新框，要么等着点窗口，两种都从十字起手。
            return input.isHoveringWindows || input.pointer != nil ? .crosshair : .arrow
        }
        guard let point = input.pointer else {
            return .arrow
        }
        if input.isCreatingSelection {
            return .crosshair
        }
        // 选中标注工具后，选区内空白处为落笔光标（十字 / 文本 I）。
        //
        // 但按住 Space 时让位：那时用户明确说了「我要拖选区」，
        // 抓手比十字更能说明「现在按住就能拖」，何况绘制手势那一刻也确实不生效。
        // 边缘和角的缩放箭头同样让位。
        if let tool = input.markupTool, tool.annotationKind != nil,
           input.selection.contains(point),
           !input.isSpacePressed {
            // 文字工具 = 文本 I；其余绘制类 = 十字准星。
            return tool == .text ? .iBeam : .crosshair
        }
        if !input.isSpacePressed, let axis = axis(at: point, selection: input.selection) {
            return .resizing(axis)
        }
        if input.isSpacePressed, input.selection.contains(point) {
            return .openHand
        }
        return input.selection.contains(point) ? .arrow : .notAllowed
    }

    /// 指针是否贴在选区边缘（含角）。也用于「按下时要不要开始缩放」。
    static func axis(
        at point: CGPoint,
        selection: CGRect,
        tolerance: CGFloat = edgeTolerance
    ) -> ResizeAxis? {
        ResizeHitZone.axis(
            at: point,
            in: selection,
            radius: tolerance,
            edgeWidth: tolerance
        )
    }
}
