import AppKit
import SwiftUI

/// 打开设置窗口，并保证它停在最前。
///
/// 菜单栏（`LSUIElement`）应用点「设置…」时有两条路径在赛跑：SwiftUI 的 `Settings`
/// 场景把窗口 order front，`ActivationPolicyController` 随后才把激活策略从
/// `.accessory` 切到 `.regular`。策略切换在 WindowServer 侧是异步的，切换过程中 App 会
/// 瞬时失去激活，于是窗口已经显示、却停在其它 App 后面——这就是「设置有时候跑到后面」
/// 的成因。
///
/// 所以这里把顺序固定下来：先切 `.regular`（窗口出现时不再触发第二次策略切换）→
/// 再开窗 → 立刻激活 → 下一轮事件循环再补一次激活。
/// 系统仍然拒绝自我激活时，用 `orderFrontRegardless()` 兜底，至少保证窗口可见，
/// 用户点一下就切到本 App（与权限引导窗口的处理一致）。
@MainActor
enum SettingsWindowPresenter {
    /// SwiftUI 的 `Settings` 窗口无法从 `NSApplication.windows` 里可靠识别
    /// （标题随系统语言变化、也没有公开的标识），由 `SettingsWindowAnchor` 登记。
    private static weak var settingsWindow: NSWindow?

    static func present(openSettings: () -> Void) {
        // 先切策略：窗口出现时不再额外做一次「accessory → regular」切换。
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        openSettings()
        activate()

        // 策略切换是异步的，紧随其后的激活请求有时被系统丢弃：
        // 下一轮事件循环（切换已落地）再补一次；已经在前台时是空操作。
        Task { @MainActor in
            await Task.yield()
            // 窗口没出来（比如设置入口不可用）：不要留下一个空 Dock 图标。
            guard ActivationPolicyController.hasRegularWindow
                || settingsWindow?.isVisible == true else {
                if NSApp.activationPolicy() == .regular {
                    NSApp.setActivationPolicy(.accessory)
                }
                return
            }
            activate()
        }
    }

    fileprivate static func register(_ window: NSWindow) {
        settingsWindow = window
    }

    private static func activate() {
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()

        guard let window = settingsWindow else { return }
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.orderFrontRegardless()
        }
    }
}

/// 把 SwiftUI 建出来的设置窗口交给 `SettingsWindowPresenter`。
///
/// 零尺寸、不参与布局，只用来在挂上窗口时拿到 `view.window`。
struct SettingsWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowReportingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowReportingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        SettingsWindowPresenter.register(window)
    }
}
