import Carbon

/// 虚拟键码 ↔ 展示名 / 字符的对照表。
///
/// 全局快捷键必须按虚拟键码存储（与键盘布局无关），展示时才翻译成用户看得懂的名字。
enum HotkeyKey {
    struct KeyDescription: Sendable {
        let name: String
        let character: Character?
    }

    nonisolated static func displayName(for keyCode: UInt32) -> String {
        table[keyCode]?.name ?? "键码 \(keyCode)"
    }

    /// 菜单 `.keyboardShortcut` 需要的字符；功能键 / 方向键等返回 `nil`，
    /// 这些键只在全局快捷键生效，不进菜单快捷键。
    nonisolated static func character(for keyCode: UInt32) -> Character? {
        table[keyCode]?.character
    }

    nonisolated static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys.contains(keyCode)
    }

    // MARK: - 系统冲突表复用

    nonisolated static let code3 = UInt32(kVK_ANSI_3)
    nonisolated static let code4 = UInt32(kVK_ANSI_4)
    nonisolated static let code5 = UInt32(kVK_ANSI_5)
    nonisolated static let code6 = UInt32(kVK_ANSI_6)
    nonisolated static let codeW = UInt32(kVK_ANSI_W)
    nonisolated static let codeQ = UInt32(kVK_ANSI_Q)
    nonisolated static let codeTab = UInt32(kVK_Tab)
    nonisolated static let codeSpace = UInt32(kVK_Space)
    nonisolated static let codeEscape = UInt32(kVK_Escape)

    // MARK: - 对照表

    private nonisolated static let functionKeys: Set<UInt32> = {
        let codes = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        return Set(codes.map(UInt32.init))
    }()

    private nonisolated static let table: [UInt32: KeyDescription] = [
        UInt32(kVK_ANSI_A): KeyDescription(name: "A", character: "a"),
        UInt32(kVK_ANSI_B): KeyDescription(name: "B", character: "b"),
        UInt32(kVK_ANSI_C): KeyDescription(name: "C", character: "c"),
        UInt32(kVK_ANSI_D): KeyDescription(name: "D", character: "d"),
        UInt32(kVK_ANSI_E): KeyDescription(name: "E", character: "e"),
        UInt32(kVK_ANSI_F): KeyDescription(name: "F", character: "f"),
        UInt32(kVK_ANSI_G): KeyDescription(name: "G", character: "g"),
        UInt32(kVK_ANSI_H): KeyDescription(name: "H", character: "h"),
        UInt32(kVK_ANSI_I): KeyDescription(name: "I", character: "i"),
        UInt32(kVK_ANSI_J): KeyDescription(name: "J", character: "j"),
        UInt32(kVK_ANSI_K): KeyDescription(name: "K", character: "k"),
        UInt32(kVK_ANSI_L): KeyDescription(name: "L", character: "l"),
        UInt32(kVK_ANSI_M): KeyDescription(name: "M", character: "m"),
        UInt32(kVK_ANSI_N): KeyDescription(name: "N", character: "n"),
        UInt32(kVK_ANSI_O): KeyDescription(name: "O", character: "o"),
        UInt32(kVK_ANSI_P): KeyDescription(name: "P", character: "p"),
        UInt32(kVK_ANSI_Q): KeyDescription(name: "Q", character: "q"),
        UInt32(kVK_ANSI_R): KeyDescription(name: "R", character: "r"),
        UInt32(kVK_ANSI_S): KeyDescription(name: "S", character: "s"),
        UInt32(kVK_ANSI_T): KeyDescription(name: "T", character: "t"),
        UInt32(kVK_ANSI_U): KeyDescription(name: "U", character: "u"),
        UInt32(kVK_ANSI_V): KeyDescription(name: "V", character: "v"),
        UInt32(kVK_ANSI_W): KeyDescription(name: "W", character: "w"),
        UInt32(kVK_ANSI_X): KeyDescription(name: "X", character: "x"),
        UInt32(kVK_ANSI_Y): KeyDescription(name: "Y", character: "y"),
        UInt32(kVK_ANSI_Z): KeyDescription(name: "Z", character: "z"),

        UInt32(kVK_ANSI_0): KeyDescription(name: "0", character: "0"),
        UInt32(kVK_ANSI_1): KeyDescription(name: "1", character: "1"),
        UInt32(kVK_ANSI_2): KeyDescription(name: "2", character: "2"),
        UInt32(kVK_ANSI_3): KeyDescription(name: "3", character: "3"),
        UInt32(kVK_ANSI_4): KeyDescription(name: "4", character: "4"),
        UInt32(kVK_ANSI_5): KeyDescription(name: "5", character: "5"),
        UInt32(kVK_ANSI_6): KeyDescription(name: "6", character: "6"),
        UInt32(kVK_ANSI_7): KeyDescription(name: "7", character: "7"),
        UInt32(kVK_ANSI_8): KeyDescription(name: "8", character: "8"),
        UInt32(kVK_ANSI_9): KeyDescription(name: "9", character: "9"),

        UInt32(kVK_ANSI_Minus): KeyDescription(name: "-", character: "-"),
        UInt32(kVK_ANSI_Equal): KeyDescription(name: "=", character: "="),
        UInt32(kVK_ANSI_LeftBracket): KeyDescription(name: "[", character: "["),
        UInt32(kVK_ANSI_RightBracket): KeyDescription(name: "]", character: "]"),
        UInt32(kVK_ANSI_Backslash): KeyDescription(name: "\\", character: "\\"),
        UInt32(kVK_ANSI_Semicolon): KeyDescription(name: ";", character: ";"),
        UInt32(kVK_ANSI_Quote): KeyDescription(name: "'", character: "'"),
        UInt32(kVK_ANSI_Comma): KeyDescription(name: ",", character: ","),
        UInt32(kVK_ANSI_Period): KeyDescription(name: ".", character: "."),
        UInt32(kVK_ANSI_Slash): KeyDescription(name: "/", character: "/"),
        UInt32(kVK_ANSI_Grave): KeyDescription(name: "`", character: "`"),

        UInt32(kVK_Return): KeyDescription(name: "↩", character: nil),
        UInt32(kVK_Tab): KeyDescription(name: "⇥", character: nil),
        UInt32(kVK_Space): KeyDescription(name: String(localized: "空格"), character: nil),
        UInt32(kVK_Delete): KeyDescription(name: "⌫", character: nil),
        UInt32(kVK_ForwardDelete): KeyDescription(name: "⌦", character: nil),
        UInt32(kVK_Escape): KeyDescription(name: "⎋", character: nil),
        UInt32(kVK_Home): KeyDescription(name: "↖", character: nil),
        UInt32(kVK_End): KeyDescription(name: "↘", character: nil),
        UInt32(kVK_PageUp): KeyDescription(name: "⇞", character: nil),
        UInt32(kVK_PageDown): KeyDescription(name: "⇟", character: nil),
        UInt32(kVK_LeftArrow): KeyDescription(name: "←", character: nil),
        UInt32(kVK_RightArrow): KeyDescription(name: "→", character: nil),
        UInt32(kVK_UpArrow): KeyDescription(name: "↑", character: nil),
        UInt32(kVK_DownArrow): KeyDescription(name: "↓", character: nil),
        UInt32(kVK_Help): KeyDescription(name: "Help", character: nil),

        UInt32(kVK_F1): KeyDescription(name: "F1", character: nil),
        UInt32(kVK_F2): KeyDescription(name: "F2", character: nil),
        UInt32(kVK_F3): KeyDescription(name: "F3", character: nil),
        UInt32(kVK_F4): KeyDescription(name: "F4", character: nil),
        UInt32(kVK_F5): KeyDescription(name: "F5", character: nil),
        UInt32(kVK_F6): KeyDescription(name: "F6", character: nil),
        UInt32(kVK_F7): KeyDescription(name: "F7", character: nil),
        UInt32(kVK_F8): KeyDescription(name: "F8", character: nil),
        UInt32(kVK_F9): KeyDescription(name: "F9", character: nil),
        UInt32(kVK_F10): KeyDescription(name: "F10", character: nil),
        UInt32(kVK_F11): KeyDescription(name: "F11", character: nil),
        UInt32(kVK_F12): KeyDescription(name: "F12", character: nil),
        UInt32(kVK_F13): KeyDescription(name: "F13", character: nil),
        UInt32(kVK_F14): KeyDescription(name: "F14", character: nil),
        UInt32(kVK_F15): KeyDescription(name: "F15", character: nil),
        UInt32(kVK_F16): KeyDescription(name: "F16", character: nil),
        UInt32(kVK_F17): KeyDescription(name: "F17", character: nil),
        UInt32(kVK_F18): KeyDescription(name: "F18", character: nil),
        UInt32(kVK_F19): KeyDescription(name: "F19", character: nil),
        UInt32(kVK_F20): KeyDescription(name: "F20", character: nil),
    ]
}
