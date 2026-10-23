import AppKit

/// 编辑器窗口的按键判定（纯逻辑，便于单测）。
///
/// 抽出来的原因是「⌫」和「⌘⌫」在编辑器里是**两个不同动作**：
/// 裸 `⌫` 删选中的标注，`⌘⌫` 删这张历史截图。两者共用同一个 keyCode，
/// 判次序一旦写错，带 command 的退格会被「删标注」那条分支吞掉，删除入口就静默失效。
enum EditorKeyCommand: Equatable, Sendable {
    /// 删掉选中的标注（裸 `⌫` / `FwDelete`）。
    case deleteSelectedAnnotation
    /// 把这张截图从历史库删掉（`⌘⌫`）。
    case deleteScreenshot
}

enum EditorKeyMapping {
    /// 退格与向前删除的 keyCode。
    static let deleteKeyCodes: Set<UInt16> = [51, 117]

    /// 把一次按键映射成命令；不归编辑器管时返回 `nil`，交给系统处理。
    ///
    /// 先判「⌫ + command」再判裸 `⌫`：两个条件互为子集，顺序反了前者永远命中不到。
    static func command(forKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> EditorKeyCommand? {
        guard deleteKeyCodes.contains(keyCode) else { return nil }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) ? .deleteScreenshot : .deleteSelectedAnnotation
    }
}
