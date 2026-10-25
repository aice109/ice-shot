import CoreGraphics

/// 标注画布上「这个位置现在该显示什么光标」的**唯一判定**。
///
/// 为什么单独抽一个纯类型：光标是这次真机上最乱的一处——同一位置该显示什么，
/// 取决于「当前工具 × 是否悬停在已有标注上 × 是否贴边 × 是否拖拽中」几件事，
/// 以前全散在 `MarkupCanvas.updateHover` 的 if/else 里，漏一条分支就是一格错光标，
/// 而且没法测。抽成纯函数后可以像查表一样对着 `docs/cursors.md` 的表格逐格验证。
///
/// 不依赖 SwiftUI / AppKit，纯输入输出，可直接单测。
///
/// 表格在 `docs/cursors.md` 的「四、标注画布」一节，
/// 与本文件、`MarkupCursorRuleTests` 三处必须一致。
enum MarkupCursorRule {
    /// 光标判定需要的全部输入。
    struct Input: Equatable {
        /// 当前工具。
        var tool: EditorTool
        /// 指针是否落在图像范围内。
        var isInsideImage: Bool
        /// 指针命中已有标注（**只有实际产生修改的区域**才算，见 `hitTest`）。
        var isOverAnnotation: Bool
        /// 正在拖拽（按下后未松手）。
        var isDragging: Bool
        /// 正在拖动的是一条已有标注（而不是在画新的）。
        var isMovingAnnotation: Bool

        init(
            tool: EditorTool,
            isInsideImage: Bool,
            isOverAnnotation: Bool = false,
            isDragging: Bool = false,
            isMovingAnnotation: Bool = false
        ) {
            self.tool = tool
            self.isInsideImage = isInsideImage
            self.isOverAnnotation = isOverAnnotation
            self.isDragging = isDragging
            self.isMovingAnnotation = isMovingAnnotation
        }
    }

    /// 给出应该显示的光标。
    ///
    /// 优先序（从高到低）——与 `docs/cursors.md` 的表格逐行对应：
    ///
    /// 1. **拖拽中不动**：拖标注 = 抓紧；画东西 = 十字。拖拽期间光标不随指针
    ///    移动而变，否则中途经过别的标注会闪一下手形。
    /// 2. **命中已有标注**：抓手。唯一例外是文字工具下的文字标注：那是进编辑，给 I-beam。
    /// 3. **图上其余位置**：绘制类工具 = 十字；文字 = I-beam；无工具态 = 箭头。
    /// 4. **图外**：由调用方决定（画布外 / 浮层选区外都是禁止）。
    ///
    /// 注意：**画布内没有图幅边缘缩放**。截图后调范围是在浮层里做的
    /// （见 `SelectionCursorRule`），编辑器内的裁剪由裁剪工具独占。
    /// 曾一度在这里加了边缘缩放箭头，但按下并不会真的缩放，只是空头支票，已移除。
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
            // 裁剪的三态（手柄 / 框内 / 框外）比通用规则细，由 `MarkupCanvas` 细化，
            // 这里给一个不会误导的兜底值。
            return .crosshair
        case .text:
            return .iBeam
        case .rectangle, .ellipse, .line, .arrow, .freehand,
             .highlighter, .number, .pixelate, .spotlight, .magnifier:
            // 选中工具后，图内除文本类一律十字准星：此刻鼠标的语义是「落笔」。
            return .crosshair
        }
    }
}
