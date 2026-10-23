import AppKit
import CoreGraphics
import Observation

/// 所有贴图窗口的唯一持有者（会话级，不落盘、不跨启动保留）。
///
/// 贴图不进 SwiftData：重启即消失，关闭即释放图像，避免第一版就引入持久化模型与迁移。
@MainActor
@Observable
final class PinBoard {
    private(set) var pins: [PinWindowController] = []
    private var nextNumber = 1

    var count: Int { pins.count }
    var isEmpty: Bool { pins.isEmpty }

    /// 打开一张贴图。
    /// - Parameters:
    ///   - image: 渲染后的结果图（含标注，所见即所得）。
    ///   - topLeft: AppKit 屏幕坐标里「贴图左上角」的位置；为空时居中在当前鼠标所在屏幕。
    @discardableResult
    func present(image: CGImage, topLeft: CGPoint? = nil) -> PinWindowController {
        let screen = topLeft.flatMap { point in
            NSScreen.screens.first { $0.frame.contains(point) }
        } ?? NSScreen.main
        let controller = PinWindowController(
            image: image,
            name: "贴图 \(nextNumber)",
            screenFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: screen?.backingScaleFactor ?? 2
        )
        nextNumber += 1

        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.pins.removeAll { $0 === controller }
        }
        pins.append(controller)
        controller.show(at: topLeft)
        return controller
    }

    func close(_ pin: PinWindowController) {
        pin.close()
    }

    func closeAll() {
        // 逐个关窗会回调 onClose 改写 pins，先拷一份再遍历。
        let current = pins
        pins.removeAll()
        for pin in current {
            pin.close()
        }
    }

    /// 把穿透中的贴图全部恢复成可交互（穿透后窗口收不到鼠标事件，只能从菜单栏找回）。
    func restoreInteraction() {
        for pin in pins where pin.isClickThrough {
            pin.setClickThrough(false)
        }
    }

    var hasClickThroughPin: Bool {
        pins.contains { $0.isClickThrough }
    }
}
