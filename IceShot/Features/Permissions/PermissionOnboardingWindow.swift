import AppKit
import Observation
import SwiftUI

/// 引导窗口的少量可变状态：是否首次启动（决定是否附加快捷键提示）。
@MainActor
@Observable
final class PermissionOnboardingModel {
    var isFirstLaunch = false
}

/// 屏幕录制权限引导窗口。
///
/// 未授权时应用启动、或用户在未授权状态下发起截图，都会打开这个窗口：
/// 一键向系统申请（`CGRequestScreenCaptureAccess`），并在系统已有记录、
/// 不会弹窗时自动把用户带到系统设置。
///
/// 之所以需要它：系统只有在应用真正发起申请时才会登记、
/// 让 IceShot 出现在「屏幕与系统音频录制」列表里；只做预检不会弹窗也不会登记。
/// 证书更换或用户从列表里移除 IceShot 后，仍然需要这条路径重新授权。
@MainActor
final class PermissionOnboardingWindowController {
    private let coordinator: CaptureCoordinator
    private let hotkeys: GlobalHotkeyManager?
    private let model = PermissionOnboardingModel()
    private var window: NSWindow?

    init(coordinator: CaptureCoordinator, hotkeys: GlobalHotkeyManager?) {
        self.coordinator = coordinator
        self.hotkeys = hotkeys
    }

    func show(firstLaunch: Bool = false) {
        coordinator.refreshPermission()
        model.isFirstLaunch = firstLaunch

        if window == nil {
            makeWindow()
        }

        // `LSUIElement` 应用在后台启动时，macOS 14+ 可能拒绝它自己激活自己：
        // 先切到 `.regular` 并请求激活；仍不是 key 窗口时用 `orderFrontRegardless()`
        // 保证窗口在最前（用户点一下即切到本应用）。
        // 窗口关闭后随 `ActivationPolicyController` 回到菜单栏形态。
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        // 系统拒绝后台激活时至少保证窗口可见：用户点一下就切到本应用。
        if window?.isKeyWindow != true {
            window?.orderFrontRegardless()
        }
    }

    private func makeWindow() {
        let view = PermissionOnboardingView(
            coordinator: coordinator,
            hotkeys: hotkeys,
            model: model,
            onClose: { [weak self] in
                self?.window?.close()
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "屏幕录制权限")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }
}

private struct PermissionOnboardingView: View {
    let coordinator: CaptureCoordinator
    let hotkeys: GlobalHotkeyManager?
    let model: PermissionOnboardingModel
    let onClose: () -> Void

    @State private var didRequestFromOnboarding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if coordinator.permissionStatus == .authorized {
                authorizedSection
            } else {
                requestSection
            }

            Divider()
            privacyNote
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            coordinator.refreshPermission()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("IceShot 需要屏幕录制权限")
                    .font(.title3.weight(.semibold))
                Text("macOS 要求你手动允许后，应用才能截取屏幕。允许一次即可，之后由菜单栏或快捷键随时截图。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 未授权

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(statusSummary, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)

            HStack(spacing: 8) {
                Button("请求屏幕录制权限") {
                    Task {
                        await requestPermission()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button("打开系统设置") {
                    coordinator.openPermissionSettings()
                }

                Button("重新检查") {
                    coordinator.refreshPermission()
                }
            }

            Text(guidanceText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isFirstLaunch, let hotkeyLine {
                Text(hotkeyLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer(minLength: 0)
                Button("稍后") {
                    onClose()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - 已授权

    private var authorizedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("已获得屏幕录制权限", systemImage: "checkmark.shield.fill")
                .font(.callout)
                .foregroundStyle(.green)

            Text("屏幕录制授权只在下次启动时生效。重启 IceShot 后即可开始截图。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("立即重启 IceShot") {
                    AppRelauncher.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Spacer(minLength: 0)

                Button("完成") {
                    onClose()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - 说明

    private var privacyNote: some View {
        Text("截图只在本机处理，不会上传；历史记录保存在本机，可在设置中关闭。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusSummary: String {
        switch coordinator.permissionStatus {
        case .authorized:
            return String(localized: "屏幕录制权限：已授权")
        case .notDetermined:
            return String(localized: "屏幕录制权限：尚未申请")
        case .denied:
            return String(localized: "屏幕录制权限：未授权")
        }
    }

    /// 点按钮时若系统静默无反应，说明系统里已有旧记录（允许或拒绝），
    /// 需要去列表里打开开关，而不是继续点按钮。
    private var guidanceText: String {
        if didRequestFromOnboarding {
            return """
            系统只在还没有 IceShot 记录时弹窗。如果刚刚没有出现弹窗：请在「系统设置 → 隐私与安全性 → \
            屏幕与系统音频录制」中打开 IceShot 的开关；列表里没有 IceShot 时，回到这里再点一次「请求屏幕录制权限」。
            """
        }
        return """
        点「请求屏幕录制权限」后系统会询问一次；若没有弹窗，请在「系统设置 → 隐私与安全性 → \
        屏幕与系统音频录制」中打开 IceShot 的开关。更换签名证书后可能需要重新确认一次。
        """
    }

    private var hotkeyLine: String? {
        guard let hotkeys else {
            return String(localized: "启动后可点菜单栏的 IceShot 图标开始截图。")
        }
        let hints = [
            (GlobalHotkeyManager.Hotkey.region, String(localized: "区域")),
            (.window, String(localized: "窗口")),
            (.fullScreen, String(localized: "全屏")),
            (.repeatRegion, String(localized: "重复上次区域")),
        ].compactMap { hotkey, name in
            hotkeys.binding(for: hotkey).map { "\($0.displayString) \(name)" }
        }
        guard !hints.isEmpty else {
            return String(localized: "启动后可点菜单栏的 IceShot 图标开始截图。")
        }
        return "启动后可用菜单栏图标或快捷键：\(hints.joined(separator: " / "))。"
    }

    private func requestPermission() async {
        didRequestFromOnboarding = true
        let status = await coordinator.requestPermission()
        if status != .authorized {
            coordinator.openPermissionSettings()
        }
    }
}
