import CoreGraphics
import Testing
@testable import IceShot

/// 放大镜裁切：光标居中、靠近边缘时平移但不越界，Retina 下换算正确。
@MainActor
struct MagnifierGeometryTests {
    @Test func cursorInMiddleCentersCrop() {
        let snapshot = MagnifierGeometry.snapshot(
            imagePixelSize: CGSize(width: 1920, height: 1080),
            cursorLocalPoint: CGPoint(x: 480, y: 270),
            displayScale: 2
        )
        #expect(snapshot?.cellSize == 4)
        #expect(snapshot?.columns == 36)
        #expect(snapshot?.rows == 28)
        #expect(snapshot?.cursorPixel == CGPoint(x: 960, y: 540))
        #expect(snapshot?.pixelRect == CGRect(x: 942, y: 526, width: 36, height: 28))
    }

    @Test func cursorNearTopLeftClampsCrop() {
        let snapshot = MagnifierGeometry.snapshot(
            imagePixelSize: CGSize(width: 1920, height: 1080),
            cursorLocalPoint: .zero,
            displayScale: 2
        )
        #expect(snapshot?.pixelRect == CGRect(x: 0, y: 0, width: 36, height: 28))
        #expect(snapshot?.cursorColumn == 0)
        #expect(snapshot?.cursorRow == 0)
    }

    @Test func cursorNearBottomRightClampsCrop() {
        let snapshot = MagnifierGeometry.snapshot(
            imagePixelSize: CGSize(width: 1920, height: 1080),
            cursorLocalPoint: CGPoint(x: 960, y: 540),
            displayScale: 2
        )
        #expect(snapshot?.pixelRect == CGRect(x: 1884, y: 1052, width: 36, height: 28))
        #expect(snapshot?.cursorColumn == 35)
        #expect(snapshot?.cursorRow == 27)
    }

    @Test func scaleChangesCellSizeButKeepsContentSize() {
        let oneX = MagnifierGeometry.snapshot(
            imagePixelSize: CGSize(width: 1920, height: 1080),
            cursorLocalPoint: CGPoint(x: 480, y: 270),
            displayScale: 1
        )
        #expect(oneX?.cellSize == 8)
        #expect(oneX?.columns == 18)
        #expect(oneX?.rows == 14)
    }

    @Test func tinyImageIsFullyCovered() {
        let snapshot = MagnifierGeometry.snapshot(
            imagePixelSize: CGSize(width: 10, height: 8),
            cursorLocalPoint: CGPoint(x: 1, y: 1),
            displayScale: 1
        )
        #expect(snapshot?.pixelRect == CGRect(x: 0, y: 0, width: 10, height: 8))
    }
}
