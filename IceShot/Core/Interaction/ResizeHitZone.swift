import CoreGraphics

/// 矩形 8 边 / 8 角的热区判定（纯几何，便于单测）。
///
/// 选区手柄与编辑器裁剪框共用：**角优先于边**，命中在「手柄中心点」周围
/// `radius` 内，这样光标提示与用户看到的小方块 / 小圆点完全对齐。
enum ResizeHitZone {
    /// 手柄命中半径（pt）：比手柄本身（7–10 pt）略大，手不需要瞄准到像素级。
    static let defaultRadius: CGFloat = 9
    /// 边命中带宽度（pt）：沿边、避开门角的一段也能给出方向光标。
    static let defaultEdgeWidth: CGFloat = 6

    /// 8 个手柄的中心点（左上原点，y 向下）。
    static func handleCenters(in rect: CGRect) -> [(axis: ResizeAxis, point: CGPoint)] {
        [
            (.topLeading, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topTrailing, CGPoint(x: rect.maxX, y: rect.minY)),
            (.leading, CGPoint(x: rect.minX, y: rect.midY)),
            (.trailing, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomLeading, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomTrailing, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
    }

    /// 指针落在哪个手柄 / 边角上。
    ///
    /// 判定顺序固定：先比距离找最近的角（避免角上的热区被边抢走），
    /// 再判边带。`rect` 太小（宽或高不足 `radius * 2`）时退化：
    /// 角落仍可命中，边上不再给提示，免得整块都是热区。
    /// - Parameters:
    ///   - point: 视图坐标（左上原点，y 向下）。
    ///   - radius: 角（及边端点）的命中半径。
    ///   - edgeWidth: 边的命中带宽。
    static func axis(
        at point: CGPoint,
        in rect: CGRect,
        radius: CGFloat = defaultRadius,
        edgeWidth: CGFloat = defaultEdgeWidth
    ) -> ResizeAxis? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        let corners = handleCenters(in: rect).filter { $0.axis.isCorner }
        if let nearest = corners.min(by: {
            distance(point, $0.point) < distance(point, $1.point)
        }), distance(point, nearest.point) <= radius {
            return nearest.axis
        }

        // 边端点（上 / 下中、左 / 右中）也按 `radius` 判定，手感与角一致。
        let edges = handleCenters(in: rect).filter { !$0.axis.isCorner }
        if let nearest = edges.min(by: {
            distance(point, $0.point) < distance(point, $1.point)
        }), distance(point, nearest.point) <= radius {
            return nearest.axis
        }

        // 退化：太窄的框不再给边带提示。
        guard rect.width >= radius * 2, rect.height >= radius * 2 else {
            return nil
        }

        let halfWidth = edgeWidth / 2
        let inVerticalSpan = point.y >= rect.minY && point.y <= rect.maxY
        let inHorizontalSpan = point.x >= rect.minX && point.x <= rect.maxX

        if inVerticalSpan {
            if abs(point.x - rect.minX) <= halfWidth { return .leading }
            if abs(point.x - rect.maxX) <= halfWidth { return .trailing }
        }
        if inHorizontalSpan {
            if abs(point.y - rect.minY) <= halfWidth { return .top }
            if abs(point.y - rect.maxY) <= halfWidth { return .bottom }
        }
        return nil
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
