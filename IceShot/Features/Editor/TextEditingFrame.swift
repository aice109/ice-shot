import AppKit
import CoreGraphics

/// 文字输入态的几何与配色：输入框里的字形、背景块与最终绘制（`EditorDrawing` 的 `.text` 分支）
/// 共用同一套换算，所以按 <kbd>Return</kbd> 提交时视觉上不跳。
///
/// 谁负责画：**输入框自己**（字号 / 文字色按最终样式给，背景块由 `MarkupCanvas` 按这里的
/// `boxRect` 画在它下面），画布在输入期间跳过这条标注。让画布单独画、输入框透明只留光标，
/// 中文输入法的组合串（marked text）会看不见；两边都画又会重影。
struct TextEditingFrame {
    /// 预览标注：与提交后落盘的标注同构，几何与颜色全部走 `EditorAnnotation` 的派生值。
    let annotation: EditorAnnotation
    /// 视图坐标：文字左上角，等于最终绘制的锚点（绘制用 `.topLeading`）。
    let textOrigin: CGPoint
    /// 视图坐标：输入框字形区；空输入 / 单个窄字符按最小宽度兜底，好让光标有位置。
    let textSize: CGSize
    /// 视图坐标：背景块（含内边距），与最终的 `textBoxRect` 同源。
    let boxRect: CGRect
    /// 视图坐标字号：与最终绘制同一个换算（原图像素字号 × 画布缩放）。
    let fontSize: CGFloat

    /// 视图坐标下给插入点留的余量：字形右边缘之外还要放得下光标。
    ///
    /// 这段**不算进** `boxRect`：提交后背景块按字形尺寸收，输入中就不该多出一截。
    static let caretAllowance: CGFloat = 2

    /// 最小字形宽度（原图像素）：空输入时按半个字留宽度。
    static func minimumTextWidth(fontSize: CGFloat) -> CGFloat {
        ceil(max(1, fontSize) * 0.5)
    }

    /// 行高（原图像素）：`measuredTextSize` 对空文字是零，空输入的高度得另有兜底。
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: max(1, fontSize), weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }

    init(text: String, origin: CGPoint, style: AnnotationStyle, layout: EditorCanvasLayout) {
        let annotation = EditorAnnotation(
            kind: .text,
            start: origin,
            end: origin,
            text: text,
            style: style
        )
        self.annotation = annotation

        let scale = max(layout.scale, 0.01)
        let measured = annotation.measuredTextSize
        let width = max(measured.width, Self.minimumTextWidth(fontSize: annotation.textFontSize))
        let height = measured.height > 0
            ? measured.height
            : Self.lineHeight(fontSize: annotation.textFontSize)
        let padding = annotation.textBackgroundPadding

        fontSize = annotation.textFontSize * scale
        textOrigin = layout.viewPoint(origin)
        textSize = CGSize(width: width * scale, height: height * scale)
        boxRect = layout.viewRect(
            CGRect(
                x: origin.x - padding,
                y: origin.y - padding,
                width: width + padding * 2,
                height: height + padding * 2
            )
        )
    }

    /// 输入框的文字色：带背景时取自动对比色，否则直接是标注色（与绘制同一条规则）。
    var textColor: NSColor {
        let color = annotation.textBackground.drawsBackground
            ? annotation.style.color.readableTextColor
            : annotation.style.color
        return color.nsColor
    }
}
