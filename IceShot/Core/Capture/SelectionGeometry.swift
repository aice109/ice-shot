import CoreGraphics

/// 区域选区的纯几何约束；不依赖 AppKit / SwiftUI，便于单元测试。
enum SelectionGeometry {
    /// - Parameters:
    ///   - lockAspect: Shift 拖拽，宽高取相同边长。
    ///   - fromCenter: Option 拖拽，以起点为中心向两侧扩展。
    static func rect(
        from anchor: CGPoint,
        to current: CGPoint,
        lockAspect: Bool,
        fromCenter: Bool
    ) -> CGRect {
        if fromCenter {
            var halfWidth = abs(current.x - anchor.x)
            var halfHeight = abs(current.y - anchor.y)
            if lockAspect {
                let side = max(halfWidth, halfHeight)
                halfWidth = side
                halfHeight = side
            }
            return CGRect(
                x: anchor.x - halfWidth,
                y: anchor.y - halfHeight,
                width: halfWidth * 2,
                height: halfHeight * 2
            )
        }

        var end = current
        if lockAspect {
            let dx = current.x - anchor.x
            let dy = current.y - anchor.y
            let side = max(abs(dx), abs(dy))
            end = CGPoint(
                x: anchor.x + (dx < 0 ? -side : side),
                y: anchor.y + (dy < 0 ? -side : side)
            )
        }
        return ScreenGeometry.normalizedRect(from: anchor, to: end)
    }

    /// 缩放现有选区；`lockAspect` 为 true 时保持原选区的宽高比。
    static func resized(
        rect: CGRect,
        handle: ResizeHandle,
        to point: CGPoint,
        lockAspect: Bool
    ) -> CGRect {
        guard lockAspect, rect.width > 0, rect.height > 0 else {
            return resizedFreely(rect: rect, handle: handle, to: point)
        }

        let aspect = rect.width / rect.height
        switch handle {
        case .topLeft:
            return cornerRect(
                anchor: CGPoint(x: rect.maxX, y: rect.maxY),
                point: point,
                aspect: aspect
            )
        case .topRight:
            return cornerRect(
                anchor: CGPoint(x: rect.minX, y: rect.maxY),
                point: point,
                aspect: aspect
            )
        case .bottomRight:
            return cornerRect(
                anchor: CGPoint(x: rect.minX, y: rect.minY),
                point: point,
                aspect: aspect
            )
        case .bottomLeft:
            return cornerRect(
                anchor: CGPoint(x: rect.maxX, y: rect.minY),
                point: point,
                aspect: aspect
            )
        case .top, .bottom:
            let anchorY = handle == .top ? rect.maxY : rect.minY
            let height = abs(point.y - anchorY)
            let width = height * aspect
            return CGRect(
                x: rect.midX - width / 2,
                y: min(anchorY, point.y),
                width: width,
                height: height
            )
        case .left, .right:
            let anchorX = handle == .left ? rect.maxX : rect.minX
            let width = abs(point.x - anchorX)
            let height = width / aspect
            return CGRect(
                x: min(anchorX, point.x),
                y: rect.midY - height / 2,
                width: width,
                height: height
            )
        }
    }

    private static func cornerRect(
        anchor: CGPoint,
        point: CGPoint,
        aspect: CGFloat
    ) -> CGRect {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let width = max(abs(dx), abs(dy) * aspect)
        let height = width / aspect
        return CGRect(
            x: dx < 0 ? anchor.x - width : anchor.x,
            y: dy < 0 ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }

    private static func resizedFreely(
        rect: CGRect,
        handle: ResizeHandle,
        to point: CGPoint
    ) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = point.x
            minY = point.y
        case .top:
            minY = point.y
        case .topRight:
            maxX = point.x
            minY = point.y
        case .right:
            maxX = point.x
        case .bottomRight:
            maxX = point.x
            maxY = point.y
        case .bottom:
            maxY = point.y
        case .bottomLeft:
            minX = point.x
            maxY = point.y
        case .left:
            minX = point.x
        }

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }
}
