import CoreGraphics

/// 图像坐标与视图坐标之间的等比缩放布局。
///
/// 图像按可用区域等比缩放并居中（四周留白 `padding`），
/// 所有绘制 / 命中测试都通过这里换算，保证标注在原图像素与屏幕 points 之间不漂移。
struct EditorCanvasLayout: Equatable {
    let imageSize: CGSize
    let viewSize: CGSize
    let padding: CGFloat
    let scale: CGFloat
    let origin: CGPoint

    init(imageSize: CGSize, viewSize: CGSize, padding: CGFloat = 24) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.padding = padding

        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            scale = 1
            origin = .zero
            return
        }

        let availableWidth = max(1, viewSize.width - padding * 2)
        let availableHeight = max(1, viewSize.height - padding * 2)
        scale = min(
            availableWidth / imageSize.width,
            availableHeight / imageSize.height
        )
        let fitted = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        origin = CGPoint(
            x: (viewSize.width - fitted.width) / 2,
            y: (viewSize.height - fitted.height) / 2
        )
    }

    /// 图像在视图坐标中的实际显示矩形。
    var imageRect: CGRect {
        CGRect(
            x: origin.x,
            y: origin.y,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    /// 图像坐标（像素）→ 视图坐标（points）。
    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + point.x * scale,
            y: origin.y + point.y * scale
        )
    }

    /// 视图坐标（points）→ 图像坐标（像素）；与 `viewPoint` 互逆。
    func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - origin.x) / scale,
            y: (point.y - origin.y) / scale
        )
    }

    /// 图像矩形 → 视图矩形（缩放 + 居中偏移）。
    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: origin.x + rect.origin.x * scale,
            y: origin.y + rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}
