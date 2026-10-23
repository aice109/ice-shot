import Carbon
import SwiftUI

/// 菜单快捷键与用户自定义配置保持一致。
///
/// 全局快捷键由 Carbon 注册；菜单里的 `.keyboardShortcut` 只是让用户看到并能从菜单触发，
/// 因此功能键（`KeyEquivalent` 无法表达）只保留全局注册，不进菜单。
struct HotkeyMenuShortcut {
    let key: KeyEquivalent
    let modifiers: SwiftUI.EventModifiers

    init?(_ binding: HotkeyBinding?) {
        guard let binding, let key = Self.keyEquivalent(for: binding.keyCode) else {
            return nil
        }
        self.key = key
        self.modifiers = Self.eventModifiers(for: binding.modifiers)
    }

    private static func keyEquivalent(for keyCode: UInt32) -> KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Return: return .return
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Delete: return .delete
        case kVK_ForwardDelete: return .deleteForward
        case kVK_Escape: return .escape
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        default:
            guard let character = HotkeyKey.character(for: keyCode) else { return nil }
            return KeyEquivalent(character)
        }
    }

    private static func eventModifiers(for modifiers: HotkeyModifiers) -> SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

extension View {
    /// 仅在配置了可映射的快捷键时附加 `.keyboardShortcut`。
    @ViewBuilder
    func menuHotkey(_ shortcut: HotkeyMenuShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}
