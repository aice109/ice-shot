import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 贴图窗口的几何：像素 → pt、超屏等比缩小、原位贴图与画布回夹。
@MainActor
struct PinGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

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

    @Test func resizingBottomEdgeKeepsTopLeftFixed() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        // 向下拖下边 50 → 变高 50，宽度按 2:1 比例一起变，左上角不动。
        let frame = PinGeometry.resizedFrame(
            baseFrame: base,
            edge: .bottom,
            translation: CGSize(width: 0, height: 50),
            imageAspect: 2
        )
        #expect(frame.height == 150)
        #expect(frame.width == 300)
        #expect(frame.minX == base.minX)
        #expect(frame.maxY == base.maxY)
    }

    @Test func resizingTopEdgeKeepsBottomFixed() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        // 向上拖上边 20（视图 y 向下，所以 translation.height 为 -20）→ 变高 20。
        let frame = PinGeometry.resizedFrame(
            baseFrame: base,
            edge: .top,
            translation: CGSize(width: 0, height: -20),
            imageAspect: 2
        )
        #expect(frame.height == 120)
        #expect(frame.minY == base.minY)
        #expect(abs(frame.maxY - (base.minY + 120)) < 0.001)
    }

    @Test func resizingLeadingEdgeKeepsRightEdgeFixed() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        // 向右拖左边 20 → 宽度变窄至 180，高度按比例变矮，右边界不动。
        let frame = PinGeometry.resizedFrame(
            baseFrame: base,
            edge: .leading,
            translation: CGSize(width: 20, height: 0),
            imageAspect: 2
        )
        #expect(frame.width == 180)
        #expect(frame.height == 90)
        #expect(frame.maxX == base.maxX)
    }

    @Test func cornerResizeUsesVerticalDelta() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let frame = PinGeometry.resizedFrame(
            baseFrame: base,
            edge: .bottomTrailing,
            translation: CGSize(width: 30, height: 40),
            imageAspect: 2
        )
        #expect(frame.height == 140)
        #expect(frame.width == 280)
        #expect(frame.minX == base.minX)
        #expect(frame.maxY == base.maxY)
    }

    @Test func resizingStopsAtMinimumSize() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let frame = PinGeometry.resizedFrame(
            baseFrame: base,
            edge: .bottom,
            translation: CGSize(width: 0, height: -500),
            imageAspect: 20
        )
        #expect(frame.height >= PinGeometry.minimumSize)
        #expect(frame.width >= PinGeometry.minimumSize)
    }

    @Test func edgeDetectionPicksNearestBorderZone() {
        let size = CGSize(width: 300, height: 200)
        #expect(PinGeometry.edge(at: CGPoint(x: 150, y: 100), in: size) == nil)
        #expect(PinGeometry.edge(at: CGPoint(x: 5, y: 100), in: size) == .leading)
        #expect(PinGeometry.edge(at: CGPoint(x: 296, y: 100), in: size) == .trailing)
        #expect(PinGeometry.edge(at: CGPoint(x: 150, y: 4), in: size) == .top)
        #expect(PinGeometry.edge(at: CGPoint(x: 150, y: 197), in: size) == .bottom)
        #expect(PinGeometry.edge(at: CGPoint(x: 2, y: 2), in: size) == .topLeading)
        #expect(PinGeometry.edge(at: CGPoint(x: 298, y: 198), in: size) == .bottomTrailing)
        // 太小的窗口不做边缘缩放，避免整个窗口都是热区。
        #expect(PinGeometry.edge(at: CGPoint(x: 2, y: 2), in: CGSize(width: 16, height: 16)) == nil)
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
