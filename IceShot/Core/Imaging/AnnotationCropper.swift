import CoreGraphics

/// 裁剪矩形与标注坐标的重映射。
///
/// 约定：所有坐标都是**原图像素、左上原点**（与 `EditorAnnotation` 一致）。
/// 裁剪后标注只做平移与裁剪，不改字号 / 线宽 / 打码强度——它们同样按原图像素定义，
/// 因此裁剪后视觉比例与原图保持一致。
enum AnnotationCropper {
    /// 裁剪框合法化：取整到整数像素、限定在图像内、至少 1 px。
    static func normalizedRect(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
        let bounds = CGRect(origin: .zero, size: imageSize)
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let standardized = rect.standardized
        let originX = standardized.origin.x.rounded()
        let originY = standardized.origin.y.rounded()
        let integral = CGRect(
            x: originX,
            y: originY,
            width: standardized.width.rounded(),
            height: standardized.height.rounded()
        )
        let clamped = integral.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// 把标注重映射到裁剪后的图像坐标系。
    ///
    /// - 矩形 / 椭圆 / 聚光灯 / 放大镜：两端点各自 clamp 进裁剪框，缩小到 1 px 以下则丢弃；
    /// - 直线 / 箭头：两端点各自 clamp，重合则丢弃；
    /// - 文字：锚点在框内才保留（文字不逐字裁切）；
    /// - 笔迹（画笔 / 高亮 / 马赛克 / 模糊）：只保留框内**最长连续点段**，
    ///   不向边界 clamp，避免沿裁剪边拉出一条假线；不足 2 点则丢弃。
    static func remap(
        _ annotations: [EditorAnnotation],
        croppingTo cropRect: CGRect
    ) -> [EditorAnnotation] {
        annotations.compactMap { remap($0, croppingTo: cropRect) }
    }

    static func remap(
        _ annotation: EditorAnnotation,
        croppingTo cropRect: CGRect
    ) -> EditorAnnotation? {
        let crop = cropRect.standardized
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        guard annotation.bounds.intersects(crop) else { return nil }

        switch annotation.kind {
        case .rectangle, .ellipse, .spotlight, .magnifier:
            var copy = annotation
            copy.start = clamp(annotation.start, to: crop)
            copy.end = clamp(annotation.end, to: crop)
            let bounds = copy.bounds
            guard bounds.width >= 1 || bounds.height >= 1 else { return nil }
            return copy.offsetBy(dx: -crop.minX, dy: -crop.minY)

        case .line, .arrow:
            var copy = annotation
            copy.start = clamp(annotation.start, to: crop)
            copy.end = clamp(annotation.end, to: crop)
            guard copy.start != copy.end else { return nil }
            return copy.offsetBy(dx: -crop.minX, dy: -crop.minY)

        case .text, .number:
            // 文字按锚点、序号按圆心判断去留（避免半截挂在裁剪边上）。
            guard contains(crop, annotation.start) else { return nil }
            return annotation.offsetBy(dx: -crop.minX, dy: -crop.minY)

        case .freehand, .highlighter, .pixelate, .blur:
            guard let run = longestVisibleRun(of: annotation.points, in: crop),
                  run.count > 1 else {
                return nil
            }
            var copy = annotation
            copy.points = run
            copy.start = run[0]
            copy.end = run[run.count - 1]
            return copy.offsetBy(dx: -crop.minX, dy: -crop.minY)
        }
    }

    /// 最长连续「落在裁剪框内」的点段；裁剪框边界视为可见。
    private static func longestVisibleRun(
        of points: [CGPoint],
        in crop: CGRect
    ) -> [CGPoint]? {
        var best: [CGPoint] = []
        var current: [CGPoint] = []
        for point in points {
            if contains(crop, point) {
                current.append(point)
                if current.count > best.count {
                    best = current
                }
            } else {
                current.removeAll(keepingCapacity: true)
            }
        }
        return best.isEmpty ? nil : best
    }

    private static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    /// 右 / 下边界视为包含，与 `clamp` 一致（避免贴边的点被整段判为不可见）。
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }
}
