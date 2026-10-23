import AppKit
import CoreGraphics

/// 打开标注编辑器的抽象入口，避免历史 / 截图流程直接持有窗口控制器。
@MainActor
protocol EditorOpening: AnyObject {
    func open(image: CGImage, title: String)
}

/// 编辑器窗口的唯一持有者。
///
/// 同一时间只保留一个标注窗口：重复打开会先关闭旧窗口，避免多个编辑器
/// 同时抢焦点、也让内存里的原图只有一份。
@MainActor
final class EditorCoordinator: EditorOpening {
    private let pins: PinBoard?
    private let feedback: FeedbackHUDController?
    private var windowController: EditorWindowController?

    init(pins: PinBoard? = nil, feedback: FeedbackHUDController? = nil) {
        self.pins = pins
        self.feedback = feedback
    }

    func open(image: CGImage, title: String) {
        windowController?.close()

        let controller = EditorWindowController(
            image: image,
            title: title,
            pins: pins,
            feedback: feedback
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller,
                  self.windowController === controller else {
                return
            }
            self.windowController = nil
        }
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // 从长截图 / 历史等其它 App 在前台的场景打开时，必须把 IceShot 自己拉到最前：
        // 菜单栏应用默认是 .accessory，只 makeKey 不足以让它盖过当前 App。
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
