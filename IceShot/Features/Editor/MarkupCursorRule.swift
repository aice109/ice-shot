import CoreGraphics

/// 标注画布上「这个位置现在该显示什么光标」的**唯一判定**。
///
/// 为什么单独抽一个纯类型：光标是这次真机上最乱的一处——同一位置该显示什么，
/// 取决于「当前工具 × 是否悬停在已有标注上 × 是否在图上 × 是否拖拽中」四件事，
/// 以前全散在 `MarkupCanvas.updateHover` 的 if/else 里，漏一条分支就是一格错光标，
/// 而且没法测。抽成纯函数后可以像查表一样对着 `ui-guidelines.md` 的表格逐格验证。
///
/// 不依赖 SwiftUI / AppKit，纯输入输出，可直接单测。
///
/// 表格在 `docs/ui-guidelines.md` 的「标注画布的光标与鼠标手势」一节，
/// 与本文件、`MarkupCursorRuleTests` 三处必须一致。
enum MarkupCursorRule {
    /// 光标判定需要的全部输入。
    struct Input: Equatable {
        /// 当前工具。
        var tool: EditorTool
        /// 指针是否落在图像范围内。
        var isInsideImage: Bool
        /// 指针是否命中一条已有标注。
        var isOverAnnotation: Bool
        /// 正在拖拽（按下后未松手）。
        var isDragging: Bool
        /// 正在拖动的是一条已有标注（而不是在画新的）。
        var isMovingAnnotation: Bool
    }

    /// 给出应该显示的光标。
    ///
    /// 优先序（从高到低）：
    /// 1. 拖拽中：拖动标注 = 抓紧；画东西 = 十字。拖拽期间光标**不随指针移动而变**，
    ///    否则中途经过别的标注会闪一下手形。
    /// 2. 命中已有标注：手形，任何工具下都一样——点住就能拖走（见 `MarkupCanvas.begin`）。
    ///    唯一例外是文字工具下的文字标注：那时点它是进编辑，光标该是 I-beam。
    /// 3. 在图上：绘制类 = 十字；文字 = I-beam；序号 = 十字；其余 = 箭头。
    /// 4. 图外：箭头。
    static func cursor(for input: Input) -> PointerCursor {
        if input.isDragging {
            // 拖动已有标注 = 抓住不放；画新东西 = 十字。
            return input.isMovingAnnotation ? .closedHand : .crosshair
        }

        if input.isOverAnnotation {
            // 文字工具点在已有文字上 = 进编辑，与双击同一个去向，光标得说同一句话。
            if input.tool == .text {
                return .iBeam
            }
            return .openHand
        }

        guard input.isInsideImage else { return .arrow }

        switch input.tool {
        case .select:
            // 无工具态：图上空白处没有特殊动作，箭头是诚实的。
            return .arrow
        case .crop:
            // 裁剪的三种状态由 `MarkupCanvas` 自己按手柄 / 框内 / 框外细化，
            // 这里给一个不会误导的兜底值。
            return .crosshair
        case .text:
            return .iBeam
        case .rectangle, .ellipse, .line, .arrow, .freehand,
             .highlighter, .number, .pixelate, .spotlight, .magnifier:
            return .crosshair
        }
    }
}
