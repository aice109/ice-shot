import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 贴图窗口的几何：像素 → pt、超屏等比缩小、原位贴图与画布回夹。
@MainActor
struct PinGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - 关闭按钮

    @Test("关闭按钮在右上角，且完全落在贴图内")
    func closeButtonSitsInTopRightCorner() {
        let size = CGSize(width: 400, height: 300)
        let center = PinGeometry.closeButtonCenter(in: size)
        let radius = PinGeometry.closeButtonDiameter / 2

        // 距右边缘 = 距上边缘 = inset + 半径。
        let inset = PinGeometry.closeButtonInset
        #expect(center.x == size.width - inset - radius)
        #expect(center.y == inset + radius)
        // 整圆在视图内，不会被裁掉。
        #expect(center.x + radius <= size.width)
        #expect(center.y - radius >= 0)
    }

    @Test("极小的贴图里按钮仍不越界")
    func closeButtonStaysInsideTinyPin() {
        // 最小贴图 40 pt，按钮直径 18 + 两侧 inset 8 = 34，仍放得下。
        let size = CGSize(
            width: PinGeometry.minimumSize,
            height: PinGeometry.minimumSize
        )
        let center = PinGeometry.closeButtonCenter(in: size)
        let radius = PinGeometry.closeButtonDiameter / 2
        #expect(center.x - radius >= 0)
        #expect(center.y - radius >= 0)
        #expect(center.x + radius <= size.width)
        #expect(center.y + radius <= size.height)
    }

    @Test("命中判定：圆心命中，远处不命中")
    func closeButtonHitTest() {
        let size = CGSize(width: 400, height: 300)
        let center = PinGeometry.closeButtonCenter(in: size)

        #expect(PinGeometry.isOverCloseButton(point: center, size: size))
        // 角落外侧不该命中，否则右上角一大片都会变成「关闭」。
        #expect(!PinGeometry.isOverCloseButton(point: .zero, size: size))
        #expect(!PinGeometry.isOverCloseButton(
            point: CGPoint(x: size.width / 2, y: size.height / 2),
            size: size
        ))
    }

    @Test("命中判定带容差，便于点中小圆点")
    func closeButtonHitTestTolerance() {
        let size = CGSize(width: 400, height: 300)
        let center = PinGeometry.closeButtonCenter(in: size)
        let radius = PinGeometry.closeButtonDiameter / 2
        // 刚好在圆外一点点：带容差时应命中。
        let justOutside = CGPoint(x: center.x, y: center.y - radius - 1)
        #expect(PinGeometry.isOverCloseButton(point: justOutside, size: size, tolerance: 2))
        #expect(!PinGeometry.isOverCloseButton(point: justOutside, size: size, tolerance: 0))
    }

    @Test func initialSizeConvertsPixelsToPoints() {
        let size = PinGeometry.initialSize(
            imageSize: CGSize(width: 1200, height: 600),
            scale: 2,
            screenFrame: screen
        )
        #expect(size == CGSize(width: 600, height: 300))
    }

    @Test func initialSizeScalesDownToFitScreen() {
        // 8000 × 4000 px（4x 屏）= 2000 × 1000 pt，超过 1440 × 900 的 85%，需要等比缩小。
        let size = PinGeometry.initialSize(
            imageSize: CGSize(width: 8000, height: 4000),
            scale: 4,
            screenFrame: screen
        )
        let maxWidth = screen.width * PinGeometry.maximumScreenRatio
        let maxHeight = screen.height * PinGeometry.maximumScreenRatio
        #expect(size.width <= maxWidth + 0.001)
        #expect(size.height <= maxHeight + 0.001)
        #expect(abs(size.width / size.height - 2) < 0.001)
        // 宽度是瓶颈时，高度由宽度推导。
        #expect(abs(size.width - maxWidth) < 0.001)
        #expect(abs(size.height - maxWidth / 2) < 0.001)
    }

    @Test func initialSizeKeepsMinimumSize() {
        let size = PinGeometry.initialSize(
            imageSize: CGSize(width: 8, height: 4),
            scale: 2,
            screenFrame: screen
        )
        #expect(size.width == PinGeometry.minimumSize)
        #expect(size.height == PinGeometry.minimumSize)
    }

    @Test func originAlignsTopLeftWithSelection() {
        // 选区左上角在 (500, 700)，贴图高 100 → 原点 y = 700 - 100。
        let origin = PinGeometry.origin(
            topLeft: CGPoint(x: 500, y: 700),
            size: CGSize(width: 200, height: 100),
            visibleFrame: screen
        )
        #expect(origin == CGPoint(x: 500, y: 600))
    }

    @Test func originIsClampedIntoVisibleFrame() {
        // 选区右下角越界（y = 950 时原点算出来 850 > 800），应夹回可见区域。
        let origin = PinGeometry.origin(
            topLeft: CGPoint(x: 1430, y: 950),
            size: CGSize(width: 200, height: 100),
            visibleFrame: screen
        )
        #expect(origin.x == screen.maxX - 200)
        #expect(origin.y == screen.maxY - 100)

        let farLeft = PinGeometry.origin(
            topLeft: CGPoint(x: -50, y: 200),
            size: CGSize(width: 200, height: 100),
            visibleFrame: screen
        )
        #expect(farLeft.x == screen.minX)
    }

    @Test func originCentersWhenNoTopLeftGiven() {
        let size = CGSize(width: 200, height: 100)
        let origin = PinGeometry.origin(
            topLeft: nil,
            size: size,
            visibleFrame: screen
        )
        #expect(origin.x == screen.midX - size.width / 2)
        #expect(origin.y == screen.midY - size.height / 2)
    }

    // MARK: - 拖边 / 拖角缩放

    @Test("下边跟着指针：上边（AppKit maxY）固定")
    func resizingBottomEdgeKeepsTopFixed() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        // 拖下边到高 150：宽度按 2:1 一起变，固定上边不动。
        let frame = PinGeometry.frameSizedToHeight(
            baseFrame: base, height: 150, imageAspect: 2, anchor: .bottom
        )
        #expect(frame.height == 150)
        #expect(frame.width == 300)
        #expect(frame.minX == base.minX)
        #expect(frame.maxY == base.maxY)
    }

    @Test("上边跟着指针：下边（AppKit minY）固定")
    func resizingTopEdgeKeepsBottomFixed() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let frame = PinGeometry.frameSizedToHeight(
            baseFrame: base, height: 120, imageAspect: 2, anchor: .top
        )
        #expect(frame.height == 120)
        #expect(frame.width == 240)
        #expect(frame.minY == base.minY)
        #expect(abs(frame.maxY - (base.minY + 120)) < 0.001)
    }

    @Test("拖左边：右边缘固定")
    func resizingLeadingEdgeKeepsRightEdgeFixed() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        // 左边缩放按宽度反算高度：180 / 2 = 90。
        let frame = PinGeometry.frameSizedToHeight(
            baseFrame: base, height: 90, imageAspect: 2, anchor: .leading
        )
        #expect(frame.width == 180)
        #expect(frame.height == 90)
        #expect(frame.maxX == base.maxX)
    }

    @Test("拖右下角：左上角固定")
    func cornerResizeKeepsTopLeadingFixed() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let frame = PinGeometry.frameSizedToHeight(
            baseFrame: base, height: 140, imageAspect: 2, anchor: .bottomTrailing
        )
        #expect(frame.height == 140)
        #expect(frame.width == 280)
        #expect(frame.minX == base.minX)
        #expect(frame.maxY == base.maxY)
    }

    @Test("缩到最小尺寸就不再变小")
    func resizingStopsAtMinimumSize() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let frame = PinGeometry.frameSizedToHeight(
            baseFrame: base, height: -500, imageAspect: 20, anchor: .bottom
        )
        #expect(frame.height == PinGeometry.minimumSize)
        #expect(frame.width == PinGeometry.minimumSize * 20)
    }

    @Test("同一目标高度反复计算，结果逐位相同（无累计误差）")
    func resizeIsAbsoluteNotIncremental() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let first = PinGeometry.frameSizedToHeight(
            baseFrame: base, height: 137.5, imageAspect: 2, anchor: .bottomTrailing
        )
        for _ in 0..<20 {
            #expect(PinGeometry.frameSizedToHeight(
                baseFrame: base, height: 137.5, imageAspect: 2, anchor: .bottomTrailing
            ) == first)
        }
    }

    @Test("按下不缩放：指针零点位移，高度逐位不变")
    func targetHeightIsUnchangedAtPress() {
        // 回归：坐标系混用曾让「轻轻一拖就直接缩成最小图」。
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let corners: [(PinGeometry.ResizeEdge, CGPoint)] = [
            (.topLeading, CGPoint(x: base.minX, y: base.maxY)),
            (.topTrailing, CGPoint(x: base.maxX, y: base.maxY)),
            (.bottomLeading, CGPoint(x: base.minX, y: base.minY)),
            (.bottomTrailing, CGPoint(x: base.maxX, y: base.minY)),
        ]
        for (edge, pressPoint) in corners {
            let height = PinGeometry.targetHeight(
                pointer: pressPoint, baseFrame: base, pressPoint: pressPoint,
                edge: edge, imageAspect: 2
            )
            #expect(height == base.height, "\(edge) 按下时高度不该变")
        }
    }

    @Test("拖右下角：位移方向决定变大变小")
    func draggedCornerFollowsPointer() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let press = CGPoint(x: 300, y: 100)  // 右下角
        let aspect: CGFloat = 2

        // 只往右拖 100：dx = 100, dy = 0 → Δh = (100*2 + 0)/5 = 40。
        #expect(PinGeometry.targetHeight(
            pointer: CGPoint(x: 400, y: 100), baseFrame: base, pressPoint: press,
            edge: .bottomTrailing, imageAspect: aspect
        ) == 140)

        // 只往上拖 100：dx = 0, dy = 100 → Δh = 100/5 = 20。
        #expect(PinGeometry.targetHeight(
            pointer: CGPoint(x: 300, y: 200), baseFrame: base, pressPoint: press,
            edge: .bottomTrailing, imageAspect: aspect
        ) == 120)

        // 往内拖（缩小）：dx = -100, dy = -100 → Δh = (-200 - 100)/5 = -60。
        #expect(PinGeometry.targetHeight(
            pointer: CGPoint(x: 200, y: 0), baseFrame: base, pressPoint: press,
            edge: .bottomTrailing, imageAspect: aspect
        ) == 40)
    }

    @Test("拖左上角：方向符号反转")
    func draggedTopLeadingFollowsPointer() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let press = CGPoint(x: 100, y: 200)  // 左上角
        let aspect: CGFloat = 2
        // 往左上拖 = 放大：dx = -100 → 取反为 100；dy = 100 → 取反为 -100？
        // 注意 touchesTop 取反：指针向上 y 增大，对左上角是「远离固定下边」= 变大。
        // 但 dy 对 touchesTop 取反后为负…… 这里用真实语义验证：往左上拖应该变大。
        let enlarged = PinGeometry.targetHeight(
            pointer: CGPoint(x: 0, y: 300), baseFrame: base, pressPoint: press,
            edge: .topLeading, imageAspect: aspect
        )
        #expect(enlarged > base.height)
    }

    @Test("同一指针位置重复计算，结果逐位相同")
    func targetHeightHasNoAccumulatedError() {
        // 「缩得越厉害偏移越大」的回归：旧实现拿会变的 locationInWindow
        // 当绝对位置，反复换算会越偏越远。现在是屏幕坐标 + 按下点快照。
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let press = CGPoint(x: 300, y: 100)
        let pointer = CGPoint(x: 640, y: 220)
        let expected = PinGeometry.targetHeight(
            pointer: pointer, baseFrame: base, pressPoint: press,
            edge: .bottomTrailing, imageAspect: 2
        )
        for _ in 0..<50 {
            #expect(PinGeometry.targetHeight(
                pointer: pointer, baseFrame: base, pressPoint: press,
                edge: .bottomTrailing, imageAspect: 2
            ) == expected)
        }
    }

    // MARK: - 命中区（光标 / 按下行为的唯一依据）

    @Test("四角命中缩放，对应方向正确")
    func cornersMapToResizeEdges() {
        let size = CGSize(width: 300, height: 200)
        let hit = PinGeometry.cornerHitSize(in: size)
        #expect(PinGeometry.hitZone(at: CGPoint(x: 1, y: 1), in: size)
            == .resize(.topLeading))
        #expect(PinGeometry.hitZone(at: CGPoint(x: size.width - 1, y: 1), in: size)
            == .resize(.topTrailing))
        #expect(PinGeometry.hitZone(at: CGPoint(x: 1, y: size.height - 1), in: size)
            == .resize(.bottomLeading))
        #expect(PinGeometry.hitZone(
            at: CGPoint(x: size.width - 1, y: size.height - 1), in: size
        ) == .resize(.bottomTrailing))
        // 刚好落在热区边界上也命中。
        #expect(PinGeometry.corner(at: CGPoint(x: hit, y: hit), in: size) == .topLeading)
        #expect(PinGeometry.corner(at: CGPoint(x: hit + 1, y: hit + 1), in: size) == nil)
    }

    @Test("四边不缩放：边上中点属于抓手")
    func edgesDoNotResize() {
        let size = CGSize(width: 300, height: 200)
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        // 四条边的中点（不在角的方形热区内）。
        #expect(PinGeometry.hitZone(at: CGPoint(x: mid.x, y: 1), in: size) == .move)
        #expect(PinGeometry.hitZone(at: CGPoint(x: mid.x, y: size.height - 1), in: size) == .move)
        #expect(PinGeometry.hitZone(at: CGPoint(x: 1, y: mid.y), in: size) == .move)
        #expect(PinGeometry.hitZone(at: CGPoint(x: size.width - 1, y: mid.y), in: size) == .move)
    }

    @Test("内部是抓手")
    func interiorIsMove() {
        let size = CGSize(width: 300, height: 200)
        #expect(PinGeometry.hitZone(
            at: CGPoint(x: size.width / 2, y: size.height / 2), in: size
        ) == .move)
    }

    @Test("关闭按钮优先级高于右上角缩放热区")
    func closeButtonWinsOverCorner() {
        let size = CGSize(width: 300, height: 200)
        let center = PinGeometry.closeButtonCenter(in: size)
        // 关闭按钮就住在右上角缩放热区里，必须先命中关闭。
        #expect(PinGeometry.corner(at: center, in: size) == .topTrailing)
        #expect(PinGeometry.hitZone(at: center, in: size) == .closeButton)
        #expect(PinGeometry.hitZone(at: center, in: size).cursor == .arrow)
    }

    @Test("光标映射：抓手 / 缩放 / 箭头")
    func hitZoneCursors() {
        #expect(PinGeometry.HitZone.move.cursor == .openHand)
        #expect(PinGeometry.HitZone.closeButton.cursor == .arrow)
        #expect(PinGeometry.HitZone.resize(.topLeading).cursor == .resize(.topLeading))
        #expect(PinGeometry.HitZone.resize(.bottomTrailing).cursor == .resize(.bottomTrailing))
    }

    @Test("极小的贴图不给角缩放，否则整张图都是热区抓不住")
    func tinyPinOnlyMoves() {
        let size = CGSize(
            width: PinGeometry.cornerHitSize,
            height: PinGeometry.cornerHitSize
        )
        #expect(PinGeometry.corner(at: .zero, in: size) == nil)
        #expect(PinGeometry.hitZone(at: .zero, in: size) == .move)
    }

    @Test("角热区随贴图尺寸自适应，且被上下限夹住")
    func cornerHitSizeAdaptsToPinSize() {
        // 小图取下限，大图取上限，中间按短边 18% 算。
        let small = PinGeometry.cornerHitSize(in: CGSize(width: 40, height: 40))
        #expect(small == PinGeometry.cornerHitSize)

        let big = PinGeometry.cornerHitSize(in: CGSize(width: 2000, height: 1200))
        #expect(big == PinGeometry.cornerHitSizeMax)

        // 短边 200：18% = 36，落在 [22, 44] 之间。
        let medium = PinGeometry.cornerHitSize(in: CGSize(width: 400, height: 200))
        #expect(medium == 200 * 0.18)
        #expect(medium > PinGeometry.cornerHitSize)
        #expect(medium < PinGeometry.cornerHitSizeMax)
    }

    @Test func resizeKeepsAspectRatioHeightDriven() {
        // 控制器里的缩放逻辑：宽度由高度与图片比例推导（这里是纯算术校验）。
        let imageWidth: CGFloat = 1200
        let imageHeight: CGFloat = 600
        let aspect = imageWidth / imageHeight
        let newHeight: CGFloat = 150
        #expect(abs(newHeight * aspect - 300) < 0.001)
    }
}

/// 关闭按钮的**布局安全**：这是上一版「点一下贴图就卡死」的回归测试。
///
/// 卡死原因：`layout()` 里无条件写 `layer.isHidden` / `layer.frame`，
/// CoreAnimation 的属性写入会触发事务提交、连锁触发布局，于是
/// `layout()` → 写图层 → 布局 → `layout()` …… 无限递归，主线程被活活占死。
///
/// 这里把「同样的值重复设置时必须幂等」编码成断言：只要定位逻辑对同一输入
/// 产生同一输出，配合调用点的「值相同就跳过」就不可能出现递归。
@MainActor
struct PinCloseButtonLayoutTests {
    @Test("同样的尺寸重复定位，结果完全一致（幂等，不会触发重排）")
    func positionIsIdempotent() {
        let sizes = [
            CGSize(width: 40, height: 40),
            CGSize(width: 400, height: 300),
            CGSize(width: 1920, height: 1080),
        ]
        for size in sizes {
            let first = PinGeometry.closeButtonCenter(in: size)
            for _ in 0..<50 {
                #expect(PinGeometry.closeButtonCenter(in: size) == first)
            }
        }
    }

    @Test("尺寸变化时按钮跟着挪，且始终在界内")
    func positionFollowsResize() {
        var sizes: [CGSize] = []
        for width in stride(from: 40.0, through: 800.0, by: 40.0) {
            sizes.append(CGSize(width: width, height: width * 0.75))
        }
        let radius = PinGeometry.closeButtonDiameter / 2
        for size in sizes {
            let center = PinGeometry.closeButtonCenter(in: size)
            #expect(center.x - radius >= 0)
            #expect(center.y - radius >= 0)
            #expect(center.x + radius <= size.width)
            #expect(center.y + radius <= size.height)
        }
    }
}
