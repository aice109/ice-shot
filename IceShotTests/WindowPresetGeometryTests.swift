import CoreGraphics
import Testing
@testable import IceShot

struct WindowPresetGeometryTests {
    private func display(
        id: CGDirectDisplayID,
        frame: CGRect,
        scale: CGFloat = 2
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            frame: frame,
            appKitFrame: frame,
            scale: scale
        )
    }

    @Test func systemSurfaceRectCoversWholeDisplayForDesktop() {
        let display = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(
            WindowPresetGeometry.systemSurfaceRect(
                windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                display: display
            ) == CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
    }

    @Test func systemSurfaceRectKeepsMenubarStrip() {
        let display = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(
            WindowPresetGeometry.systemSurfaceRect(
                windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 30),
                display: display
            ) == CGRect(x: 0, y: 0, width: 1000, height: 30)
        )
    }

    @Test func systemSurfaceRectClipsToDisplayAndRejectsOtherDisplay() {
        let secondary = display(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        #expect(
            WindowPresetGeometry.systemSurfaceRect(
                windowFrame: CGRect(x: 900, y: 700, width: 400, height: 200),
                display: secondary
            ) == CGRect(x: 0, y: 700, width: 300, height: 100)
        )
        #expect(
            WindowPresetGeometry.systemSurfaceRect(
                windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                display: secondary
            ) == nil
        )
    }

    @Test func whatYouSeeRectFollowsWindowFrame() {
        // 所见即所得：点击悬停高亮的窗口时，裁切矩形就是该窗口在屏幕上的可见矩形。
        // 冻结帧里这块矩形已经合成了叠在上面的通知 / 菜单 / 其他窗口，
        // 所以直接裁它就能把那些内容一并截到——这正是需求要的行为。
        let display = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let window = CGRect(x: 100, y: 60, width: 500, height: 400)

        let rect = WindowPresetGeometry.systemSurfaceRect(
            windowFrame: window,
            display: display
        )

        #expect(rect == window)
    }

    @Test func windowInsideDisplayMapsToLocalRect() throws {
        let display = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let geometry = try #require(
            WindowPresetGeometry.make(
                windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300),
                imageSize: CGSize(width: 800, height: 600),
                displays: [display]
            )
        )

        #expect(geometry.displayID == 1)
        #expect(geometry.displayLocalRect == CGRect(x: 100, y: 50, width: 400, height: 300))
        #expect(geometry.imagePixelRect == CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func windowClippedToDisplayCropsImage() throws {
        let display = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let geometry = try #require(
            WindowPresetGeometry.make(
                windowFrame: CGRect(x: 800, y: 700, width: 400, height: 300),
                imageSize: CGSize(width: 800, height: 600),
                displays: [display]
            )
        )

        #expect(geometry.displayLocalRect == CGRect(x: 800, y: 700, width: 200, height: 100))
        // 遮挡部分按比例裁掉：右侧 100 pt（200 px）、下方 200 pt（400 px）。
        #expect(geometry.imagePixelRect == CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    @Test func picksDisplayWithLargestOverlap() throws {
        let left = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let right = display(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))

        let geometry = try #require(
            WindowPresetGeometry.make(
                windowFrame: CGRect(x: 800, y: 100, width: 600, height: 300),
                imageSize: CGSize(width: 1200, height: 600),
                displays: [left, right]
            )
        )

        #expect(geometry.displayID == 2)
        #expect(geometry.displayLocalRect == CGRect(x: 0, y: 100, width: 400, height: 300))
        #expect(geometry.imagePixelRect == CGRect(x: 400, y: 0, width: 800, height: 600))
    }

    @Test func offscreenWindowReturnsNil() {
        let display = display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let geometry = WindowPresetGeometry.make(
            windowFrame: CGRect(x: 2000, y: 100, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200),
            displays: [display]
        )
        #expect(geometry == nil)
    }
}
