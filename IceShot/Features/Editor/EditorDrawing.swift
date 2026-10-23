import SwiftUI

/// 把标注模型绘制到 SwiftUI `GraphicsContext`。
///
/// 所有坐标都在图像像素空间，绘制前统一经 `EditorCanvasLayout` 换算到视图空间；
/// 线宽也按 `scale` 缩放，保证缩放窗口时标注与原图的相对比例不变。
enum EditorDrawing {
    /// `source` 只有需要采样原图的标注（放大镜）才用到；其余标注传 `nil` 即可。
    static func draw(
        _ annotation: EditorAnnotation,
        in context: inout GraphicsContext,
        layout: EditorCanvasLayout,
        source: CGImage? = nil
    ) {
        let color = annotation.style.color.color
        let lineWidth = max(1, annotation.style.lineWidth * layout.scale)
        context.opacity = annotation.style.opacity
        context.blendMode = annotation.kind == .highlighter ? .multiply : .normal
        let strokeStyle = StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round
        )

        switch annotation.kind {
        case .rectangle:
            let rect = layout.viewRect(annotation.bounds)
            context.stroke(
                Path(rect),
                with: .color(color),
                style: strokeStyle
            )
        case .ellipse:
            let rect = layout.viewRect(annotation.bounds)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(color),
                style: strokeStyle
            )
        case .line:
            var path = Path()
            path.move(to: layout.viewPoint(annotation.start))
            path.addLine(to: layout.viewPoint(annotation.end))
            context.stroke(path, with: .color(color), style: strokeStyle)
        case .arrow:
            drawArrow(
                annotation,
                in: &context,
                layout: layout,
                color: color,
                strokeStyle: strokeStyle
            )
        case .freehand, .highlighter:
            guard let first = annotation.points.first else { return }
            var path = Path()
            path.move(to: layout.viewPoint(first))
            for point in annotation.points.dropFirst() {
                path.addLine(to: layout.viewPoint(point))
            }
            context.stroke(path, with: .color(color), style: strokeStyle)
        case .text:
            guard let text = annotation.text, !text.isEmpty else { return }
            let background = annotation.textBackground
            var textColor = color
            if background.drawsBackground {
                let box = layout.viewRect(annotation.textBoxRect)
                context.fill(
                    Path(
                        roundedRect: box,
                        cornerRadius: annotation.textBackgroundCornerRadius * layout.scale
                    ),
                    with: .color(color.opacity(background.fillOpacity))
                )
                // 底色是标注色，文字得取反一些才能读；白字压白底是最常见的「看不见」。
                textColor = annotation.style.color.readableTextColor.color
            }
            let resolved = context.resolve(
                Text(text)
                    .font(
                        .system(
                            size: max(1, annotation.textFontSize * layout.scale),
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(textColor)
            )
            context.draw(resolved, at: layout.viewPoint(annotation.start), anchor: .topLeading)
        case .number:
            guard let number = annotation.number else { return }
            let diameter = annotation.numberDiameter * layout.scale
            let center = layout.viewPoint(annotation.start)
            let rect = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
            // 徽章底色可能与截图内容撞色，加一圈白色描边保证边界清楚。
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(.white.opacity(0.9)),
                style: StrokeStyle(lineWidth: max(1, layout.scale))
            )
            let label = context.resolve(
                Text("\(number)")
                    .font(.system(size: max(1, diameter * 0.55), weight: .bold))
                    .foregroundStyle(.white)
            )
            context.draw(label, at: center, anchor: .center)
        case .pixelate, .blur:
            // 需要原图像素，由调用方（MarkupCanvas / EditorRenderView）绘制滤镜结果。
            break
        case .magnifier:
            drawMagnifier(
                annotation,
                in: &context,
                layout: layout,
                source: source,
                color: color
            )
        case .spotlight:
            // 整幅图压暗，挖掉区域那一块：even-odd 填充一次画完，不需要原图像素。
            // 颜色用黑色是「压暗」本身（与高亮用 `.multiply` 同理），不是语义色选择。
            let spotlight = annotation.spotlightStyle
            let hole = layout.viewRect(annotation.bounds)
            var path = Path()
            path.addRect(layout.imageRect)
            switch spotlight.shape {
            case .ellipse:
                path.addEllipse(in: hole)
            case .rectangle:
                path.addRect(hole)
            }
            context.fill(
                path,
                with: .color(.black.opacity(spotlight.clampedDim)),
                style: FillStyle(eoFill: true)
            )
        }
    }

    /// 放大镜：把原图按倍数放大、以框中心为锚重新摆好，再裁到框内；
    /// 最后描一圈标注色的边，让它在导出结果里也能看出是个「镜头」。
    ///
    /// 用 `GraphicsContext` 的副本做裁剪，裁剪范围不会泄漏到后面的其它标注。
    private static func drawMagnifier(
        _ annotation: EditorAnnotation,
        in context: inout GraphicsContext,
        layout: EditorCanvasLayout,
        source: CGImage?,
        color: Color
    ) {
        let magnifier = annotation.magnifierStyle
        let box = layout.viewRect(annotation.bounds)
        let clipPath = magnifier.shape == .ellipse
            ? Path(ellipseIn: box)
            : Path(box)

        if let source {
            let scale = layout.scale * magnifier.clampedZoom
            let bounds = annotation.bounds
            let origin = CGPoint(
                x: box.midX - bounds.midX * scale,
                y: box.midY - bounds.midY * scale
            )
            let drawnRect = CGRect(
                x: origin.x,
                y: origin.y,
                width: CGFloat(source.width) * scale,
                height: CGFloat(source.height) * scale
            )
            var inset = context
            inset.clip(to: clipPath)
            inset.draw(
                Image(decorative: source, scale: 1).interpolation(.high),
                in: drawnRect
            )
        }

        context.stroke(
            clipPath,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }

    /// 选中态虚线框；额外外扩 3pt，避免贴在标注边缘上看不清。
    static func drawSelection(
        _ annotation: EditorAnnotation,
        in context: inout GraphicsContext,
        layout: EditorCanvasLayout
    ) {
        let rect = layout.viewRect(annotation.selectionBounds).insetBy(dx: -3, dy: -3)
        context.opacity = 1
        context.blendMode = .normal
        context.stroke(
            Path(rect),
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )
    }

    /// 箭头 = 主干线 + 两条按线宽缩放的箭头边。
    private static func drawArrow(
        _ annotation: EditorAnnotation,
        in context: inout GraphicsContext,
        layout: EditorCanvasLayout,
        color: Color,
        strokeStyle: StrokeStyle
    ) {
        let start = layout.viewPoint(annotation.start)
        let end = layout.viewPoint(annotation.end)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color), style: strokeStyle)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(9, strokeStyle.lineWidth * 3.5)
        let spread = CGFloat.pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        var head = Path()
        head.move(to: left)
        head.addLine(to: end)
        head.addLine(to: right)
        context.stroke(head, with: .color(color), style: strokeStyle)
    }
}
