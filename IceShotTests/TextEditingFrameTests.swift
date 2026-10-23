import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 文字输入态（所见即所得）的几何：输入框里的字形与背景块必须和提交后绘制的完全一致，
/// 否则按 <kbd>Return</kbd> 的瞬间会跳一下——那正是这个单元要解决的问题。
@MainActor
struct TextEditingFrameTests {
    private let layout = EditorCanvasLayout(
        imageSize: CGSize(width: 800, height: 600),
        viewSize: CGSize(width: 400, height: 300),
        padding: 0
    )

    private func style(
        color: EditorColor = .defaultRed,
        fontSize: CGFloat = 32,
        background: TextBackgroundStyle? = nil
    ) -> AnnotationStyle {
        AnnotationStyle(
            color: color,
            lineWidth: 1,
            opacity: 1,
            fontSize: fontSize,
            textBackground: background
        )
    }

    @Test func textStartsAtTheSameAnchorAsDrawing() {
        let origin = CGPoint(x: 120, y: 90)
        let frame = TextEditingFrame(
            text: "IceShot 标注",
            origin: origin,
            style: style(),
            layout: layout
        )
        // 绘制用 `context.draw(..., at: viewPoint(start), anchor: .topLeading)`。
        #expect(frame.textOrigin == layout.viewPoint(origin))
        #expect(frame.annotation.start == origin)
        // 输入框字号就是最终绘制字号（原图像素 × 画布缩放），不做「可读性」放大。
        #expect(abs(frame.fontSize - 32 * layout.scale) < 0.001)
    }

    @Test func backgroundBoxMatchesFinalTextBox() {
        let frame = TextEditingFrame(
            text: "一段够宽的文字",
            origin: CGPoint(x: 40, y: 60),
            style: style(background: .solid),
            layout: layout
        )
        // 文字宽过最小宽度，所以预览块就该与 `textBoxRect` 一模一样（含内边距）。
        #expect(frame.boxRect == layout.viewRect(frame.annotation.textBoxRect))
        #expect(frame.boxRect.width > frame.textSize.width)
        #expect(frame.boxRect.height > frame.textSize.height)
    }

    @Test func backgroundBoxIsSymmetricForTranslucent() {
        let frame = TextEditingFrame(
            text: "半透底",
            origin: CGPoint(x: 40, y: 60),
            style: style(background: .translucent),
            layout: layout
        )
        let padding = frame.annotation.textBackgroundPadding * layout.scale
        #expect(abs((frame.textOrigin.x - frame.boxRect.minX) - padding) < 0.001)
        #expect(abs((frame.textOrigin.y - frame.boxRect.minY) - padding) < 0.001)
        #expect(abs((frame.boxRect.maxX - (frame.textOrigin.x + frame.textSize.width)) - padding) < 0.001)
    }

    @Test func emptyTextKeepsRoomForCaret() {
        let frame = TextEditingFrame(
            text: "",
            origin: CGPoint(x: 10, y: 20),
            style: style(fontSize: 40),
            layout: layout
        )
        let minimum = TextEditingFrame.minimumTextWidth(fontSize: 40) * layout.scale
        #expect(abs(frame.textSize.width - minimum) < 0.001)
        #expect(frame.textSize.height > 0)
        #expect(frame.annotation.measuredTextSize == .zero)
    }

    @Test func textColorFollowsBackgroundContrast() {
        let plain = TextEditingFrame(
            text: "x",
            origin: .zero,
            style: style(color: .builtInPalette[6], background: nil),
            layout: layout
        )
        // 无背景：文字就是标注色本身。
        #expect(plain.textColor == EditorColor.builtInPalette[6].nsColor)

        let solid = TextEditingFrame(
            text: "x",
            origin: .zero,
            style: style(color: .builtInPalette[7], background: .solid),
            layout: layout
        )
        // 白底实底：文字取对比色（黑），否则就是白字压白底。
        #expect(solid.textColor == EditorColor.readableDark.nsColor)
    }
}
