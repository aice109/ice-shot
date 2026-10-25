import AppKit
import Testing
@testable import IceShot

/// 贴图窗口的创建与展示：这里锁住「创建不能重入 AppKit 布局」这条约定。
///
/// 背景（真机事故）：点工具栏「贴图」后整机卡死，日志停在 `CFPrefsD` 之后没有下一行。
/// 根因是在 `SelectionOverlayView` 的按钮 action 同步栈里创建 `NSPanel`——
/// 那一刻浮层面板正在拆除、AppKit 处于事件分发重入点，新窗口的首帧布局
/// 与正在进行的拆除互相等待。
///
/// 因此 `CaptureCoordinator.pinResult` 把创建推迟到下一个 `Task`。
/// 这里验证的是**贴图本体在窗口之外也能安全构造**，以及可以连续创建多张。
@MainActor
struct PinPresentationTests {
    @Test("贴图面板创建后不立即上屏，show 之后才可见")
    func pinIsHiddenUntilShown() {
        let controller = PinWindowController(
            image: Self.makeImage(),
            name: "贴图 1",
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 2
        )
        #expect(controller.window?.isVisible == false)

        controller.show(at: nil)
        #expect(controller.window?.isVisible == true)

        controller.close()
        #expect(controller.window?.isVisible == false)
    }

    @Test("可以连续贴多张，互不干扰")
    func multiplePinsCoexist() {
        let board = PinBoard()
        let image = Self.makeImage()

        let first = board.present(image: image)
        let second = board.present(image: image)

        #expect(board.count == 2)
        #expect(first !== second)

        board.close(first)
        #expect(board.count == 1)

        board.closeAll()
        #expect(board.isEmpty)
    }

    @Test("内容视图在 init 阶段不依赖 backing layer")
    func contentViewDoesNotTouchLayerInInit() {
        let controller = PinWindowController(
            image: Self.makeImage(),
            name: "贴图 1",
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 2
        )
        // 关键：构造完成即代表 contentView 已就位（不崩、不卡）。
        #expect(controller.window?.contentView is PinImageView)
        controller.close()
    }

    private static func makeImage() -> CGImage {
        let width = 4
        let height = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context!.makeImage()!
    }
}
