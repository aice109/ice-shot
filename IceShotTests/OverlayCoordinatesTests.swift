import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 屏幕 ↔ 浮层视图坐标换算。
///
/// 这套换算曾经在三个地方各写一遍、且写法不一致：鼠标监视器用
/// `contentView.bounds.height` 翻转 y，另外两处用 `appKitFrame.maxY - mouse.y`。
/// 真机表现就是「指针明明在选区里，顶部一点却判成选区外 → 显示禁止光标」。
/// 这里把边界钉死：屏幕上下左右四个角都必须落到视图坐标的对应角上。
struct OverlayCoordinatesTests {
    /// 主屏：1920×1080，AppKit 坐标主屏左下角为原点、y 向上。
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test("屏幕四角映射到视图四角")
    func cornersMapToCorners() throws {
        // 屏幕左上角（AppKit y 最大）→ 视图左上 (0, 0)
        let topLeft = try #require(
            OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: 0, y: 1080), displayFrame: display)
        )
        #expect(topLeft == CGPoint(x: 0, y: 0))

        // 屏幕右下角 → 视图右下
        let bottomRight = try #require(
            OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: 1920, y: 0), displayFrame: display)
        )
        #expect(bottomRight == CGPoint(x: 1920, y: 1080))
    }

    @Test("屏幕中心映射到视图中心")
    func centerMapsToCenter() throws {
        let point = try #require(
            OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: 960, y: 540), displayFrame: display)
        )
        #expect(point == CGPoint(x: 960, y: 540))
    }

    @Test("顶部一点必须落在视图顶部附近，不能跑到下方")
    func topOfScreenIsTopOfView() throws {
        // 距屏幕上边缘 5 pt：视图坐标里 y 也必须很小。
        let point = try #require(
            OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: 500, y: 1075), displayFrame: display)
        )
        #expect(point.y == 5)
        #expect(point.y < 100)
    }

    @Test("副屏（带原点偏移）同样正确")
    func secondaryDisplayWithOffset() throws {
        // 副屏挂在主屏右侧：AppKit 坐标 x 从 1920 起，y 仍向上。
        let secondary = CGRect(x: 1920, y: 0, width: 1280, height: 800)
        let point = try #require(
            OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: 1920 + 100, y: 800 - 50), displayFrame: secondary)
        )
        #expect(point == CGPoint(x: 100, y: 50))
    }

    @Test("指针不在这块屏幕上时返回 nil")
    func pointsOutsideDisplayReturnNil() {
        #expect(OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: -10, y: 500), displayFrame: display) == nil)
        #expect(OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: 500, y: 2000), displayFrame: display) == nil)
    }

    @Test("窗口坐标换算与屏幕坐标换算必须一致：同一位置两条路径不能算出两个答案")
    func windowAndScreenConversionsAgree() throws {
        // 同一块屏幕：面板 frame 就是 appKitFrame，屏幕 y 与窗口 y 都向上、数值相同。
        let fromScreen = try #require(
            OverlayCoordinates.viewPoint(fromScreen: CGPoint(x: 600, y: 900), displayFrame: display)
        )
        let fromWindow = OverlayCoordinates.viewPoint(
            fromWindow: CGPoint(x: 600, y: 900),
            windowHeight: display.height
        )
        #expect(fromScreen == fromWindow)
        // 屏幕 y=900 距上边缘 180 → 视图 y=180。
        #expect(fromScreen.y == 180)
    }

    @Test("屏幕边界上的点算在这块屏幕上：否则最上一行永远判成选区外")
    func boundaryPointsBelongToDisplay() {
        // CGRect.contains 是半开的，直接用会把 maxX / maxY 排除掉。
        #expect(OverlayCoordinates.containsInclusive(display, CGPoint(x: 0, y: 1080)))
        #expect(OverlayCoordinates.containsInclusive(display, CGPoint(x: 1920, y: 0)))
        #expect(OverlayCoordinates.containsInclusive(display, CGPoint(x: 1920, y: 1080)))
    }

    @Test("顶部一点：窗口路径也不能判到下方")
    func windowConversionTopStaysTop() {
        let point = OverlayCoordinates.viewPoint(
            fromWindow: CGPoint(x: 300, y: 1075),
            windowHeight: 1080
        )
        #expect(point.y == 5)
    }
}
