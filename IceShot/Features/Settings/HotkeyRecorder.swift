import AppKit
import Carbon
import Observation

/// 快捷键录制：点击「录制」后本地监听按键，把组合写回 `GlobalHotkeyManager`。
///
/// 用 `NSEvent.addLocalMonitorForEvents` 而不是全局监听：只在 IceShot 自己的窗口有焦点时
/// 工作，不需要辅助功能 / 输入监控权限。录制期间先挂起全局热键，否则 Carbon 会先吞掉按键。
@MainActor
@Observable
final class HotkeyRecorder {
    private(set) var recordingHotkey: GlobalHotkeyManager.Hotkey?
    private(set) var pressedModifiers: HotkeyModifiers = []
    /// 录制结果提示（错误 / 已清除）。
    private(set) var message: String?

    private weak var manager: GlobalHotkeyManager?
    private var monitor: Any?

    var isRecording: Bool { recordingHotkey != nil }

    func isRecording(_ hotkey: GlobalHotkeyManager.Hotkey) -> Bool {
        recordingHotkey == hotkey
    }

    func toggle(for hotkey: GlobalHotkeyManager.Hotkey, manager: GlobalHotkeyManager) {
        if recordingHotkey == hotkey {
            cancel()
        } else {
            begin(for: hotkey, manager: manager)
        }
    }

    func begin(for hotkey: GlobalHotkeyManager.Hotkey, manager: GlobalHotkeyManager) {
        cancel()
        self.manager = manager
        recordingHotkey = hotkey
        pressedModifiers = []
        message = nil
        manager.beginRecording()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // 本地监听器固定回到主线程，只把基础类型带过隔离边界。
            let consumed = MainActor.assumeIsolated {
                self.handle(type: event.type, keyCode: event.keyCode, flags: event.modifierFlags)
            }
            return consumed ? nil : event
        }
    }

    func cancel() {
        stopMonitor()
        manager?.endRecording()
        manager = nil
        recordingHotkey = nil
        pressedModifiers = []
    }

    // MARK: - 按键处理

    /// 返回 `true` 表示事件已被录制消费。
    private func handle(
        type: NSEvent.EventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard let hotkey = recordingHotkey, let manager else { return false }

        switch type {
        case .flagsChanged:
            pressedModifiers = Self.modifiers(from: flags)
            return true

        case .keyDown:
            let modifiers = Self.modifiers(from: flags)

            if keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                cancel()
                return true
            }

            // 无修饰键的 Delete / 前向删除：清除这条快捷键。
            if modifiers.isEmpty,
               keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete) {
                finish(
                    hotkey: hotkey,
                    binding: nil,
                    manager: manager
                )
                return true
            }

            finish(
                hotkey: hotkey,
                binding: HotkeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers),
                manager: manager
            )
            return true

        default:
            return false
        }
    }

    private func finish(
        hotkey: GlobalHotkeyManager.Hotkey,
        binding: HotkeyBinding?,
        manager: GlobalHotkeyManager
    ) {
        stopMonitor()
        self.manager = nil
        recordingHotkey = nil
        pressedModifiers = []

        // 先恢复注册再改配置，冲突检测才能拿到真实的注册结果。
        manager.endRecording()

        switch manager.setBinding(binding, for: hotkey) {
        case .applied:
            message = binding == nil ? "已清除「\(hotkey.displayName)」的快捷键。" : nil
        case .rejectedDuplicate(let other):
            message = "该组合已用于「\(other.displayName)」，请换一个。"
        case .rejectedInvalid:
            message = "全局快捷键至少需要 ⌘ / ⌃ / ⌥ 之一（功能键除外）。"
        case .rejectedRegistrationFailure:
            message = "「\(binding?.displayString ?? "")」已被其它应用占用，已恢复到原快捷键。"
        }
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
