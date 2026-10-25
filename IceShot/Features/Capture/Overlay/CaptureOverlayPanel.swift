import AppKit
import SwiftUI

final class CaptureOverlayPanel: NSPanel {
    /// Esc 的处理者（由 `SelectionOverlayController` 注入）。
    ///
    /// `NSPanel` 默认会把 Esc 走成 `performClose:`——整个浮层直接消失、也不落历史记录。
    /// 取字模式这类「模式」状态下更是灾难：Live Text 的文本视图会先把 Esc 让出来，
    /// 结果整次截图没了。这里统一交给控制器按 `EditorEscapeAction` 判定。
    var onCancelOperation: (() -> Void)?

    /// 取字模式下 Esc 的兜底：`performKeyEquivalent` 比响应链更早，能拦住
    /// 被 Live Text 文本选择视图吃掉的 Esc。返回 `true` 表示已处理。
    ///
    /// 只在取字模式生效——行内文字编辑器的 Esc 要留给它自己取消，不能被这里抢走。
    var onTextPickingEscape: (() -> Bool)?

    /// 只有协调器真正收尾（`dismiss()`）时才允许关闭。
    ///
    /// 取字模式下 Esc 会被 Live Text 内部消化，谁都收不到通知，但系统仍可能按面板默认
    /// 行为把窗口关掉；与其到处猜 Esc 落到哪一层，不如直接让面板**关不掉**：
    /// 任何 `close()` / `performClose(_:)` 都转成 Esc 语义交给控制器。
    var allowsClose = false

    /// 指针在浮层上的实时位置（视图坐标，左上原点），由系统鼠标移动事件驱动。
    ///
    /// 为什么不能只靠 SwiftUI 的 `onContinuousHover`：那个回调由**视图内部的追踪区**
    /// 驱动，只在指针进入并移动于该视图时才有事件。框选完成后，指针若停在某个子视图
    /// （手柄 / 工具条 / 画布）上、或停在两层之间的空隙里，父层的 hover 就不再更新，
    /// 光标要等到下一次点击让视图重建才变——这正是「不是实时变化、点击后才变」。
    /// 这里用窗口级监视器：只要指针在浮层上动，就一定会回调。
    var onPointerMoved: ((CGPoint) -> Void)?
    private var pointerMonitor: Any?

    /// 装上 / 卸下鼠标移动监视器（`present` 时装，`dismiss` 时卸）。
    func startPointerTracking() {
        stopPointerTracking()
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            guard let self, event.window === self else { return event }
            let point = Self.viewPoint(for: event, in: self)
            self.onPointerMoved?(point)
            return event
        }
    }

    /// 事件位置 → 浮层视图坐标（左上原点，单位 points）。
    ///
    /// 换算必须与 `SelectionOverlayView.initialCursorPosition()` / 控制器首帧播种
    /// 用**同一个公式**：那两处都是
    /// `x = mouse.x - appKitFrame.minX`、`y = appKitFrame.maxY - mouse.y`。
    /// 之前这里用 `contentView.bounds.height - inView.y`，一旦 `NSHostingView` 的
    /// bounds 原点或高度与面板 frame 不同（多屏、非主屏、含标题栏时都会不同），
    /// y 就会整体偏移一格——表现正是「顶部一点就变成禁用」。
    static func viewPoint(for event: NSEvent, in panel: NSPanel) -> CGPoint {
        OverlayCoordinates.viewPoint(
            fromWindow: event.locationInWindow,
            windowHeight: panel.frame.height
        )
    }

    func stopPointerTracking() {
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
        }
        pointerMonitor = nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        EscapeTrace.log("panel.performClose")
        requestEscape()
    }

    override func close() {
        guard !allowsClose, onCancelOperation != nil else {
            EscapeTrace.log("panel.close", "allowed")
            super.close()
            return
        }
        EscapeTrace.log("panel.close", "blocked")
        requestEscape()
    }

    /// 把「要关闭」翻译成 Esc 语义：取字模式先退取字，其余交给控制器。
    private func requestEscape() {
        if onTextPickingEscape?() == true { return }
        onCancelOperation?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
            let handled = onTextPickingEscape?() == true
            EscapeTrace.log("panel.performKeyEquivalent", "handled=\(handled)")
            if handled {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard let onCancelOperation else {
            EscapeTrace.log("panel.cancelOperation", "unhandled")
            super.cancelOperation(sender)
            return
        }
        EscapeTrace.log("panel.cancelOperation", "routed")
        onCancelOperation()
    }

    override func becomeKey() {
        super.becomeKey()
        if let contentView {
            makeFirstResponder(contentView)
        }
    }
}

/// 让第一次点击就进入交互，而不是只激活窗口。
///
/// 刻意使用非泛型的 `NSHostingView<AnyView>`：泛型子类会让 Swift 6.2（Xcode 26）
/// 在 IRGen 阶段为合成的 `deinit` 崩溃，Xcode 27 才修复。改用 AnyView 规避，
/// 浮层内容本来就小，性能开销可忽略。
final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// 吞掉 Space 的按键，不让 SwiftUI 键盘系统看到。
    ///
    /// 修的是真机上「按住 Space 哒哒哒一直响」：
    /// 浮层用 `NSEvent.addLocalMonitorForEvents` 监听 Space，但那个监测器只能拦住
    /// 事件向**其它** responder 的分发，拦不住 `NSHostingView` 自己那套 SwiftUI
    /// 键盘处理（`onKeyPress` / 焦点系统）。Space 在 SwiftUI 里不是被绑定的快捷键，
    /// 于是当成「未处理的按键」发出系统提示音；长按产生重复 keyDown，就响成一片。
    ///
    /// 在 responder 链的入口处直接吃掉 Space，声音就从根上没了。
    /// 真实逻辑仍由 `localMonitor` 写状态（监测器看得到同一事件）。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // Space：按住拖移选区，交给监测器，不响铃
            return
        }
        super.keyDown(with: event)
    }
}
