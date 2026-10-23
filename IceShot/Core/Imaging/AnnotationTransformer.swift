import CoreGraphics

/// 旋转 / 翻转时标注坐标的重映射。
///
/// 约定与 `EditorAnnotation` 一致：原图像素、**左上原点**、y 向下。
/// 设原图 W × H，映射规则：
/// - 顺时针 90°：`(x, y) → (H - y, x)`，画布变为 `H × W`
/// - 逆时针 90°：`(x, y) → (y, W - x)`，画布变为 `H × W`
/// - 水平翻转：`(x, y) → (W - x, y)`
/// - 垂直翻转：`(x, y) → (x, H - y)`
///
/// 文字标注**保持正立**（模型没有旋转字段），只平移锚点；锚点被推出画布时
/// clamp 回可见区域，保证文字整体仍在图内。
enum AnnotationTransformer {
    static func rotated(
        _ annotations: [EditorAnnotation],
        imageSize: CGSize,
        clockwise: Bool
    ) -> [EditorAnnotation] {
        transform(annotations, newImageSize: swapped(imageSize)) { point in
            clockwise
                ? CGPoint(x: imageSize.height - point.y, y: point.x)
                : CGPoint(x: point.y, y: imageSize.width - point.x)
        }
    }

    static func flipped(
        _ annotations: [EditorAnnotation],
        imageSize: CGSize,
        horizontal: Bool
    ) -> [EditorAnnotation] {
        transform(annotations, newImageSize: imageSize) { point in
            horizontal
                ? CGPoint(x: imageSize.width - point.x, y: point.y)
                : CGPoint(x: point.x, y: imageSize.height - point.y)
        }
    }

    private static func transform(
        _ annotations: [EditorAnnotation],
        newImageSize: CGSize,
        map: (CGPoint) -> CGPoint
    ) -> [EditorAnnotation] {
        annotations.map { annotation in
            var copy = annotation
            copy.start = map(annotation.start)
            copy.end = map(annotation.end)
            copy.points = annotation.points.map(map)
            if annotation.kind == .text {
                return clampedText(copy, imageSize: newImageSize)
            }
            return copy
        }
    }

    private static func swapped(_ size: CGSize) -> CGSize {
        CGSize(width: size.height, height: size.width)
    }

    private static func clampedText(
        _ annotation: EditorAnnotation,
        imageSize: CGSize
    ) -> EditorAnnotation {
        // 背景块也要在图内：先把占位框夹到画布里，再反推字形锚点
        // （`start` 是字形左上角，背景向外扩一个内边距）。
        let textSize = annotation.measuredTextSize
        let padding = annotation.textBackgroundPadding
        let boxSize = CGSize(
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        var copy = annotation
        let boxX = min(
            max(annotation.start.x - padding, 0),
            max(0, imageSize.width - boxSize.width)
        )
        let boxY = min(
            max(annotation.start.y - padding, 0),
            max(0, imageSize.height - boxSize.height)
        )
        copy.start = CGPoint(x: boxX + padding, y: boxY + padding)
        copy.end = copy.start
        return copy
    }
}
