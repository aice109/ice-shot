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
}
