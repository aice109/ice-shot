import AppKit
import SwiftUI

/// 设置窗口：屏幕录制权限、截图说明、历史记录、全局快捷键与关于。
///
/// 权限状态与快捷键注册都以 `CaptureCoordinator` / `GlobalHotkeyManager` 为准，
/// 本视图只触发操作并展示结果，不复制业务状态。
struct SettingsView: View {
    let coordinator: CaptureCoordinator
    let hotkeys: GlobalHotkeyManager?
    let library: LibraryStore?

    @AppStorage(HistoryPreferences.enabledKey) private var historyEnabled = true
    @AppStorage(OCRPreferences.autoRecognizeKey) private var autoRecognize = true
    @Environment(\.openWindow) private var openWindow
    @State private var recorder = HotkeyRecorder()
    @State private var launchAtLogin = LaunchAtLoginModel()

    var body: some View {
        Form {
            generalSection

            Section("屏幕录制权限") {
                LabeledContent("状态", value: coordinator.permissionSummary)
                HStack {
                    if coordinator.permissionStatus != .authorized {
                        Button("授予屏幕录制权限…") {
                            NotificationCenter.default.post(
                                name: .iceShotShowPermissionOnboarding,
                                object: nil
                            )
                        }
                    }
                    Button("重新检查") {
                        coordinator.refreshPermission()
                    }
                    Button("打开系统设置") {
                        coordinator.openPermissionSettings()
                    }
                    Button("重启 IceShot") {
                        AppRelauncher.relaunch()
                    }
                }
                Text("授权只在下次启动时生效：在系统设置中打开 IceShot 的开关后，点「重启 IceShot」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("截图") {
                Text("区域 / 窗口 / 全屏截图可从菜单栏或菜单「截图」启动。")
                    .foregroundStyle(.secondary)
                Text("全屏截图使用光标所在显示器；全部显示器会逐屏截取，可保存多张 PNG。")
                    .foregroundStyle(.secondary)
                Text("延时截图支持区域 / 窗口 / 全屏 / 全部显示器，倒计时期间可取消。")
                    .foregroundStyle(.secondary)
            }

            PaletteEditor()

            Section("历史记录") {
                Toggle("自动保存截图到历史", isOn: $historyEnabled)
                Text("本机保存最近 30 天 / 500 张 / 2 GB；收藏不会被自动清理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("保存后自动识别文字", isOn: $autoRecognize)
                    .disabled(!historyEnabled)
                Text("用系统 Vision 在本机识别，便于搜索；不联网、不上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开历史记录") {
                    openWindow(id: "library")
                    NSApplication.shared.activate()
                }
                .disabled(library == nil)
            }

            hotkeySection

            Section("关于") {
                // 版本号只读 Bundle，不能在界面里写死；打包脚本可覆盖 MARKETING_VERSION。
                LabeledContent("版本", value: AppVersion.displayText)
                if AppVersion.channel.isBeta {
                    Text("当前是 Beta 预览版：功能与界面仍可能调整；问题请反馈。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("截图默认只在本机处理，不上传。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        // 让 `SettingsWindowPresenter` 拿到窗口：激活被系统拒绝时它要能兜底置前。
        .background(SettingsWindowAnchor())
        .onAppear {
            // 用户可能在系统设置里改过登录项，打开设置页时先对一次真实状态。
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 从「系统设置 > 登录项」切回来时，开关要跟着系统的真实状态走。
            launchAtLogin.refresh()
        }
        .onDisappear {
            // 设置窗口关闭时结束录制，避免本地监听泄漏。
            recorder.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // 切到其它 App 后本地监听收不到按键；结束录制，让全局热键立即恢复。
            recorder.cancel()
        }
    }

    // MARK: - 通用

    /// 开机自启动：开关值来自系统登录项状态，开启 / 关闭失败会回滚并给出原因。
    private var generalSection: some View {
        Section("通用") {
            Toggle(
                "开机时自动启动",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )

            Text("登录后自动在菜单栏启动 IceShot。关闭后仍可从启动台手动打开。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let hint = launchAtLogin.locationHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = launchAtLogin.systemHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if launchAtLogin.showsSystemSettingsButton {
                Button("打开登录项设置") {
                    launchAtLogin.openSystemSettings()
                }
            }

            if let failure = launchAtLogin.failureMessage {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 全局快捷键

    /// 全局快捷键列表：录制 / 重置 / 全量恢复默认，并把冲突与注册失败直接展示出来。
    private var hotkeySection: some View {
        Section("全局快捷键") {
            ForEach(GlobalHotkeyManager.Hotkey.allCases) { hotkey in
                hotkeyRow(hotkey)
            }

            HStack {
                Button("全部恢复默认") {
                    recorder.cancel()
                    hotkeys?.resetAllBindings()
                }
                .disabled(hotkeys == nil)

                Spacer(minLength: 0)
            }

            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = hotkeys?.registrationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("点「录制」后按下新组合；Delete 清除，Esc 取消。功能键可单独使用，其它键至少需要 ⌘ / ⌃ / ⌥ 之一。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hotkeyRow(_ hotkey: GlobalHotkeyManager.Hotkey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(hotkey.displayName) {
                HStack(spacing: 8) {
                    Text(shortcutText(for: hotkey))
                        .monospacedDigit()
                        .foregroundStyle(recorder.isRecording(hotkey) ? Color.accentColor : Color.primary)
                        .frame(minWidth: 72, alignment: .trailing)
                        .accessibilityLabel("\(hotkey.displayName)当前快捷键")

                    Button(recorder.isRecording(hotkey) ? "取消" : "录制") {
                        guard let hotkeys else { return }
                        recorder.toggle(for: hotkey, manager: hotkeys)
                    }
                    .buttonStyle(.bordered)
                    .disabled(hotkeys == nil)

                    Button("重置") {
                        recorder.cancel()
                        hotkeys?.resetBinding(for: hotkey)
                    }
                    .buttonStyle(.borderless)
                    .disabled(hotkeys == nil || hotkeys?.binding(for: hotkey) == hotkey.defaultBinding)
                }
            }

            ForEach(hotkeys?.warnings(for: hotkey) ?? [], id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcutText(for hotkey: GlobalHotkeyManager.Hotkey) -> String {
        guard recorder.isRecording(hotkey) else {
            return hotkeys?.label(for: hotkey) ?? "未设置"
        }
        let modifiers = recorder.pressedModifiers.symbol
        return modifiers.isEmpty ? "按下组合键…" : "\(modifiers)…"
    }
}
