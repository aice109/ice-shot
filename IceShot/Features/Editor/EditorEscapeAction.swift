import Foundation

/// `Esc` 的统一优先级：**先退「模式」（取字、二级选项浮窗），再关 / 取消截图**。
///
/// 截取浮层里 `Esc` 能落到三个地方——面板级键盘监听、浮层视图的 `onKeyPress`、
/// `CaptureOverlayPanel.cancelOperation`（`NSPanel` 默认会把 Esc 变成 `performClose:`，
/// 整个浮层直接消失）。三处都走这一个判定，避免某条路径漏判、把整次截图关掉。
enum EditorEscapeAction: Equatable {
    /// 退出取字模式，回到编辑态。
    case exitTextPicking
    /// 关掉二级选项浮窗。
    case closeOptions
    /// 结束这次就地编辑（关闭浮层，原图已在历史里）。
    case closeEditing
    /// 还在框选阶段：取消这次截图。
    case cancelCapture

    static func resolve(
        isTextPicking: Bool,
        hasOptions: Bool,
        isEditing: Bool
    ) -> EditorEscapeAction {
        if isTextPicking { return .exitTextPicking }
        if hasOptions { return .closeOptions }
        return isEditing ? .closeEditing : .cancelCapture
    }

    /// 用当前编辑状态判定（浮层视图与控制器共用）。
    static func resolve(editor: EditorModel?, isEditing: Bool) -> EditorEscapeAction {
        resolve(
            isTextPicking: editor?.isTextPicking == true,
            hasOptions: editor?.optionsTarget != nil,
            isEditing: isEditing
        )
    }
}

/// 同一个 `Esc` 可能被多层看到（面板级监听 / SwiftUI `onKeyPress` / 窗口 `cancelOperation`），
/// 只有第一次算数。
///
/// 必要性来自实测：监听先把「取字」退掉并消费事件，之后 SwiftUI 的 handler 仍被调用了一次，
/// 那时状态看起来「没有模式」，于是把整次截图关掉。有了这道闸门，第二层只会是空操作。
struct EscapeGate {
    /// 同一个物理按键在各层之间的间隔是毫秒级；人手连按两次也远大于这个窗口。
    static let interval: TimeInterval = 0.12

    private var lastHandled = -TimeInterval.greatestFiniteMagnitude

    mutating func shouldHandle(at now: TimeInterval) -> Bool {
        guard now - lastHandled >= Self.interval else { return false }
        lastHandled = now
        return true
    }
}
