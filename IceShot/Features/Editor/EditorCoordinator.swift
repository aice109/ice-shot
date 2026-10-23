import AppKit
import CoreGraphics

/// 打开标注编辑器的抽象入口，避免历史 / 截图流程直接持有窗口控制器。
@MainActor
protocol EditorOpening: AnyObject {
    /// - Parameter target: 这张图的来源。从历史库打开时传 `.history`，编辑器才有删除入口；
    ///   截图 / 长截图进编辑器传默认的 `.standalone`。
    func open(image: CGImage, title: String, target: EditorTarget)
}

@MainActor
extension EditorOpening {
    /// 截图 / 长截图直接进编辑器的调用点用这个：没有历史记录可删。
    func open(image: CGImage, title: String) {
        open(image: image, title: title, target: .standalone)
    }
}

/// 给编辑器提供删除能力的入口。
///
/// 编辑器只持有 `UUID`（拿到的是解码后的 `CGImage`），删除前要先换回 SwiftData 引用，
/// 所以把 `LibraryStore` 当作依赖注入，而不是让编辑器自己去开 context。
@MainActor
protocol EditorDeleting: AnyObject {
    /// 删掉这条历史记录（原图 + 缩略图 + 记录本身）。
    /// - Returns: `false` 表示记录已不存在（可能已被别处删除），调用方按「已删掉」处理即可。
    func deleteRecord(id: UUID) async throws -> Bool
}

/// 编辑器窗口的唯一持有者。
///
/// 同一时间只保留一个标注窗口：重复打开会先关闭旧窗口，避免多个编辑器
/// 同时抢焦点、也让内存里的原图只有一份。
@MainActor
final class EditorCoordinator: EditorOpening {
    private let pins: PinBoard?
    private let feedback: FeedbackHUDController?
    /// 历史库；为 `nil` 时编辑器没有删除入口（与 `.standalone` 表现一致）。
    private let library: LibraryStore?
    private var windowController: EditorWindowController?

    init(
        pins: PinBoard? = nil,
        feedback: FeedbackHUDController? = nil,
        library: LibraryStore? = nil
    ) {
        self.pins = pins
        self.feedback = feedback
        self.library = library
    }

    func open(image: CGImage, title: String, target: EditorTarget) {
        windowController?.close()

        let controller = EditorWindowController(
            image: image,
            title: title,
            pins: pins,
            feedback: feedback,
            deleter: library,
            target: target
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
