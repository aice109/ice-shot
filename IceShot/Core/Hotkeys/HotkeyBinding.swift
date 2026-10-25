import Foundation

/// 全局快捷键的修饰键组合，脱离 Carbon / AppKit 的纯数据表示。
///
/// 只描述「用户按下了哪些修饰键」，具体按键由 `HotkeyBinding.keyCode` 表示，
/// 存 `UserDefaults` 时也不需要把组合拼成字符串。
struct HotkeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    static let command = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let control = HotkeyModifiers(rawValue: 1 << 2)
    static let shift = HotkeyModifiers(rawValue: 1 << 3)

    /// 允许出现在全局快捷键里的全部修饰键。
    static let supported: HotkeyModifiers = [.command, .option, .control, .shift]

    /// 至少要有 ⌘ / ⌃ / ⌥ 之一：纯字母或纯 ⇧ 组合会抢走全局输入，不接受。
    var isValidForGlobalHotkey: Bool {
        !intersection([.command, .option, .control]).isEmpty
    }

    /// 系统标准顺序：⌃ ⌥ ⇧ ⌘。
    var symbol: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

extension HotkeyModifiers: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt32.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 一条全局快捷键：虚拟键码 + 修饰键。
///
/// Carbon 注册与设置页展示都从同一个值派生，避免「提示的快捷键」和「实际注册的快捷键」不一致。
struct HotkeyBinding: Hashable, Sendable, Codable {
    var keyCode: UInt32
    var modifiers: HotkeyModifiers

    var displayString: String {
        modifiers.symbol + HotkeyKey.displayName(for: keyCode)
    }

    /// 与系统 / 常见 App 已占用的组合对照，用于给出「能注册但会抢键」的提醒。
    var systemConflict: String? {
        Self.systemConflicts[self]
    }

    /// Carbon 不会因为「系统菜单快捷键」而注册失败，这一类冲突只能靠静态清单提示。
    private static let systemConflicts: [HotkeyBinding: String] = [
        HotkeyBinding(keyCode: HotkeyKey.code3, modifiers: [.command, .shift]):
            String(localized: "与系统截图（⇧⌘3 / 4 / 5 / 6）冲突，注册后会抢占系统截图。"),
        HotkeyBinding(keyCode: HotkeyKey.code4, modifiers: [.command, .shift]):
            String(localized: "与系统截图（⇧⌘3 / 4 / 5 / 6）冲突，注册后会抢占系统截图。"),
        HotkeyBinding(keyCode: HotkeyKey.code5, modifiers: [.command, .shift]):
            String(localized: "与系统截图（⇧⌘3 / 4 / 5 / 6）冲突，注册后会抢占系统截图。"),
        HotkeyBinding(keyCode: HotkeyKey.code6, modifiers: [.command, .shift]):
            String(localized: "与系统截图（⇧⌘3 / 4 / 5 / 6）冲突，注册后会抢占系统截图。"),
        HotkeyBinding(keyCode: HotkeyKey.codeW, modifiers: [.command, .shift]):
            String(localized: "与绝大多数 App 的「关闭窗口」（⇧⌘W）冲突，注册后它们将无法使用该组合。"),
        HotkeyBinding(keyCode: HotkeyKey.codeQ, modifiers: [.command, .shift]):
            String(localized: "与系统「退出登录」（⇧⌘Q）冲突，建议避开。"),
        HotkeyBinding(keyCode: HotkeyKey.codeTab, modifiers: .command):
            String(localized: "与系统「切换 App」（⌘⇥）冲突，注册后会失效。"),
        HotkeyBinding(keyCode: HotkeyKey.codeSpace, modifiers: .command):
            String(localized: "与系统「聚焦搜索 / Spotlight」（⌘Space）冲突，注册后会失效。"),
        HotkeyBinding(keyCode: HotkeyKey.codeEscape, modifiers: [.command, .option]):
            String(localized: "与系统「强制退出」（⌥⌘⎋）冲突，注册后会失效。"),
    ]
}
