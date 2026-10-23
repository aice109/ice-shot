import CoreGraphics

/// 放大镜的裁切范围。
///
/// 坐标均为静态帧的像素坐标（左上原点）；`cellSize` 是一个源像素在浮层上占用的 points。
struct MagnifierSnapshot: Equatable, Sendable {
    let pixelRect: CGRect
    let cursorPixel: CGPoint
    let cellSize: CGFloat

    var columns: Int { Int(pixelRect.width) }
    var rows: Int { Int(pixelRect.height) }
    var cursorColumn: Int { Int(cursorPixel.x - pixelRect.minX) }
    var cursorRow: Int { Int(cursorPixel.y - pixelRect.minY) }
}

/// 放大镜几何计算：决定裁切哪一块源像素、显示多少列 / 行。
///
/// 独立成纯函数便于单元测试，不依赖视图或屏幕状态。
enum MagnifierGeometry {
    /// 放大镜内容区的目标尺寸（points）。
    static let targetSize = CGSize(width: 144, height: 112)
    /// 8× 像素级放大，保证每个源像素都能被网格清楚分开。
    static let magnification: CGFloat = 8

    /// 以光标所在像素为中心裁切；靠近图像边缘时自动平移，不越界。
    static func snapshot(
        imagePixelSize: CGSize,
        cursorLocalPoint: CGPoint,
        displayScale: CGFloat,
        targetSize: CGSize = targetSize,
        magnification: CGFloat = magnification
    ) -> MagnifierSnapshot? {
        guard displayScale > 0,
              magnification > 0,
              imagePixelSize.width >= 1,
              imagePixelSize.height >= 1 else {
            return nil
        }

        let imageWidth = Int(imagePixelSize.width)
        let imageHeight = Int(imagePixelSize.height)
        let cellSize = magnification / displayScale
        let columns = min(
            imageWidth,
            max(1, Int((targetSize.width / cellSize).rounded(.down)))
        )
        let rows = min(
            imageHeight,
            max(1, Int((targetSize.height / cellSize).rounded(.down)))
        )

        let cursorX = min(
            max(Int((cursorLocalPoint.x * displayScale).rounded(.down)), 0),
            imageWidth - 1
        )
        let cursorY = min(
            max(Int((cursorLocalPoint.y * displayScale).rounded(.down)), 0),
            imageHeight - 1
        )
        let originX = min(max(cursorX - columns / 2, 0), max(0, imageWidth - columns))
        let originY = min(max(cursorY - rows / 2, 0), max(0, imageHeight - rows))

        return MagnifierSnapshot(
            pixelRect: CGRect(
                x: originX,
                y: originY,
                width: columns,
                height: rows
            ),
            cursorPixel: CGPoint(x: cursorX, y: cursorY),
            cellSize: cellSize
        )
    }
}
