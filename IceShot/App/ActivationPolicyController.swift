import AppKit

/// 菜单栏优先的应用默认没有 Dock 图标（`LSUIElement`）。
///
/// 但是一旦打开设置 / 历史记录 / 编辑器这类**常规窗口**，macOS 用户预期 Dock 里能看到
/// 应用、能用 <kbd>⌘</kbd><kbd>Tab</kbd> 切回来；因此这里在运行时切换激活策略：
///
/// - 有常规窗口 → `.regular`（显示 Dock 图标，并把窗口带到前台）；
/// - 最后一个常规窗口关闭 → `.accessory`（Dock 图标立即消失，回到菜单栏常驻形态）。
///
/// 判定只看「能成为主窗口、层级为 normal 的非 panel 窗口」：菜单栏面板、截取浮层、
/// 倒计时 HUD、颜色面板都是 `NSPanel`，不会被误判成常规窗口。
@MainActor
final class ActivationPolicyController {
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        observers = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 正在关闭的窗口在通知发出时仍算 isVisible，
                    // 等这一轮事件循环结束再判断，才能看到「最后一个窗口已关」。
                    Task { @MainActor in
                        self.refresh()
                    }
                }
            }
        }
        refresh()
    }

    /// 是否存在常规窗口（设置 / 历史库 / 编辑器）。
    /// 截取浮层、菜单栏面板、HUD 都是 `NSPanel`，不算在内。
    static var hasRegularWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && window.canBecomeMain
                && window.level == .normal
                && !(window is NSPanel)
        }
    }

    private func refresh() {
        if Self.hasRegularWindow {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        } else {
            guard NSApp.activationPolicy() != .accessory else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
