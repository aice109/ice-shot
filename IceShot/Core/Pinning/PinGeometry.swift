import CoreGraphics

/// 贴图窗口的尺寸与位置计算（纯几何，便于单测）。
///
/// 约定：`topLeft` 与 `origin` 都在 AppKit 屏幕坐标（左下原点）里表达，
/// 但调用方传入的是「贴图显示的左上角点」，更贴近截图选区的直觉。
enum PinGeometry {
    /// 缩到最小也不能小于这个尺寸（pt），否则抓不住也看不清。
    static let minimumSize: CGFloat = 40
    /// 贴图初始不得超出所在屏幕可用区域的比例。
    static let maximumScreenRatio: CGFloat = 0.85

    /// 初始显示尺寸：按屏幕缩放把像素换算成 pt，超屏时等比缩小。
    static func initialSize(
        imageSize: CGSize,
        scale: CGFloat,
        screenFrame: CGRect
    ) -> CGSize {
        let pointScale = max(scale, 1)
        let width = max(1, imageSize.width) / pointScale
        let height = max(1, imageSize.height) / pointScale

        let maxWidth = max(minimumSize, screenFrame.width * maximumScreenRatio)
        let maxHeight = max(minimumSize, screenFrame.height * maximumScreenRatio)
        let factor = min(1, min(maxWidth / width, maxHeight / height))

        return CGSize(
            width: max(minimumSize, width * factor),
            height: max(minimumSize, height * factor)
        )
    }

    /// 窗口原点（AppKit 左下原点）。
    /// - `topLeft` 非空时按「贴图左上角对齐这个点」摆放（截图选区原位贴图）；
    /// - 为空时居中在 `visibleFrame`。
    /// 结果总会被夹进可见区域，避免贴图跑到屏幕外拿不回来。
    static func origin(
        topLeft: CGPoint?,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let anchor = topLeft ?? CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY + size.height / 2
        )
        let x = clamp(
            anchor.x,
            lower: visibleFrame.minX,
            upper: max(visibleFrame.minX, visibleFrame.maxX - size.width)
        )
        let y = clamp(
            anchor.y - size.height,
            lower: visibleFrame.minY,
            upper: max(visibleFrame.minY, visibleFrame.maxY - size.height)
        )
        return CGPoint(x: x, y: y)
    }

    /// 缩放的拖动边 / 角。
    enum ResizeEdge: Equatable {
        case top, bottom, leading, trailing
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var touchesLeft: Bool { self == .leading || self == .topLeading || self == .bottomLeading }
        var touchesRight: Bool { self == .trailing || self == .topTrailing || self == .bottomTrailing }
        var touchesTop: Bool { self == .top || self == .topLeading || self == .topTrailing }
        var touchesBottom: Bool { self == .bottom || self == .bottomLeading || self == .bottomTrailing }

        /// 光标提示用的统一方向（`PointerCursor` 只认 `ResizeAxis`）。
        var axis: ResizeAxis {
            switch self {
            case .top: return .top
            case .bottom: return .bottom
            case .leading: return .leading
            case .trailing: return .trailing
            case .topLeading: return .topLeading
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
    }

    /// 缩放后的窗口 frame（AppKit 坐标）。
    ///
    /// - 保持图片比例（内容不能变形），最小 `minimumSize`；
    /// - 拖动哪条边就固定对面那条边：拖左边 → 右边不动，拖上边 → 下边不动。
    /// - `translation` 是 SwiftUI 视图坐标位移（y 向下）。
    static func resizedFrame(
        baseFrame: CGRect,
        edge: ResizeEdge,
        translation: CGSize,
        imageAspect: CGFloat
    ) -> CGRect {
        guard imageAspect > 0, baseFrame.width > 0, baseFrame.height > 0 else {
            return baseFrame
        }

        var height: CGFloat
        if edge.touchesTop || edge.touchesBottom {
            // 上下边 / 角：竖直位移决定高度；向下拖下边变高，向下拖上边变矮。
            let delta = edge.touchesBottom ? translation.height : -translation.height
            height = baseFrame.height + delta
        } else {
            // 只有左右边：水平位移决定宽度，再按比例换算高度。
            let delta = edge.touchesRight ? translation.width : -translation.width
            height = (baseFrame.width + delta) / imageAspect
        }

        height = max(minimumSize, height)
        let width = max(minimumSize, height * imageAspect)

        let originX = edge.touchesLeft ? baseFrame.maxX - width : baseFrame.minX
        let originY = edge.touchesTop ? baseFrame.minY : baseFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// 指针落在哪条边 / 角上（`inset` 为热区宽度，view 坐标、y 向下）。
    static func edge(
        at point: CGPoint,
        in size: CGSize,
        inset: CGFloat = 10
    ) -> ResizeEdge? {
        guard size.width > inset * 2, size.height > inset * 2 else { return nil }
        let left = point.x <= inset
        let right = point.x >= size.width - inset
        let top = point.y <= inset
        let bottom = point.y >= size.height - inset

        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeading
        case (_, true, true, _): return .topTrailing
        case (true, _, _, true): return .bottomLeading
        case (_, true, _, true): return .bottomTrailing
        case (true, _, _, _): return .leading
        case (_, true, _, _): return .trailing
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
