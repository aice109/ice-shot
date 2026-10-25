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
    @AppStorage(CapturePreferences.countdownSecondsKey)
    private var countdownSeconds = CapturePreferences.defaultCountdownSeconds
    @Environment(\.openWindow) private var openWindow
    @State private var recorder = HotkeyRecorder()
    @State private var launchAtLogin = LaunchAtLoginModel()
    /// 界面语言。启动时从实际偏好读一次，之后的变更直接写入 `AppleLanguages`。
    @State private var languageChoice = LanguagePreferences.currentChoice()

    /// 选的语言和当前跑的进程不是一个，就得重启才能看到效果。
    private var languageNeedsRestart: Bool {
        LanguagePreferences.needsRestart(choice: languageChoice)
    }

    var body: some View {
        // 分页而不是竖向平铺：设置项原本是 6 组平铺，纵向远超一屏，
        // 用户必须一路滚动才能找到「快捷键」或「关于」。
        // macOS 的系统设置本身就用分页，这也是 Mac 用户最熟悉的形式。
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            captureTab
                .tabItem { Label("截图与标注", systemImage: "camera.viewfinder") }
            hotkeyTab
                .tabItem { Label("快捷键", systemImage: "command") }
            historyTab
                .tabItem { Label("历史记录", systemImage: "photo.stack") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        // 560 宽：给快捷键行（名称 + 组合 + 两个按钮）留够横向空间。
        // 620 高：最高的「截图与标注」页（含 8 行色板）接近放得下，
        // 再多就要滚，但那一页的内容本身就没有定长（色板可增删到 2–8 色）。
        .frame(width: 560, height: 620)
        // 让 `SettingsWindowPresenter` 拿到窗口：激活被系统拒绝时它要能兜底置前。
        .background(SettingsWindowAnchor())
        .onAppear {
            // 用户可能在系统设置里改过登录项，打开设置页时先对一次真实状态。
            launchAtLogin.refresh()
            // 语言同理：系统设置里能单 App 指定语言，打开时以磁盘上的真实值为准。
            languageChoice = LanguagePreferences.currentChoice()
        }
        .onChange(of: languageChoice) { _, newValue in
            // macOS 在进程启动时解析 .lproj，所以这里只落盘，不期望界面立刻变。
            // 是否变生效由 `languageNeedsRestart` 算出来，不一致就给重启按钮。
            LanguagePreferences.apply(newValue)
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

    // MARK: - 分页

    /// 「通用」页：界面语言、开机自启动、屏幕录制权限。
    ///
    /// 权限放这里而不是单开一页：它只在「还不能截图」时需要处理，
    /// 和语言 / 登录项一样属于「应用整体状态」，凑一页正好一屏。
    private var generalTab: some View {
        Form {
            generalSection

            Section("屏幕录制权限") {
                LabeledContent(String(localized: "状态"), value: coordinator.permissionSummary)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// 「截图与标注」页：截图行为、标注色板。
    private var captureTab: some View {
        Form {
            Section("截图") {
                Picker("延时截图", selection: $countdownSeconds) {
                    ForEach(CapturePreferences.countdownOptions, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                Text("菜单「截图 > 延时截图」倒计时结束后开始区域截图；倒计时期间可取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("区域 / 窗口 / 全屏可从菜单栏或菜单「截图」启动；全屏使用光标所在显示器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PaletteEditor()
        }
        .formStyle(.grouped)
    }

    /// 「快捷键」页：单独一页放。
    ///
    /// 五个快捷键每个都带「当前组合 + 录制 + 重置」，一组就近 300pt；
    /// 跟截图、色板挤在同一页会滚动超过一屏，拆开各自都能一眼看全。
    private var hotkeyTab: some View {
        Form {
            hotkeySection
        }
        .formStyle(.grouped)
    }

    /// 「历史记录」页：开关、容量说明、打开历史窗口。
    private var historyTab: some View {
        Form {
            Section("历史记录") {
                Toggle("自动保存截图到历史", isOn: $historyEnabled)
                Text("本机保存最近 30 天 / 500 张 / 2 GB；收藏不会被自动清理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("保存后自动识别文字", isOn: $autoRecognize)
                    .disabled(!historyEnabled)
                Text("用系统 Vision 在本机识别，便于搜索；不联网、不上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("打开历史记录") {
                    openWindow(id: "library")
                    NSApplication.shared.activate()
                }
                .disabled(library == nil)
            }
        }
        .formStyle(.grouped)
    }

    /// 「关于」页：版本、通道、仓库与发布页入口、隐私说明。
    private var aboutTab: some View {
        Form {
            Section("关于") {
                // 版本号只读 Bundle，不能在界面里写死；打包脚本可覆盖 MARKETING_VERSION。
                LabeledContent(String(localized: "版本"), value: AppVersion.displayText)
                if AppVersion.channel.isBeta {
                    Text("当前是 Beta 预览版：功能与界面仍可能调整；问题请反馈。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("在 GitHub 上查看源码") {
                        open(ProjectLinks.repository)
                    }
                    Button("前往发布页下载新版本") {
                        open(ProjectLinks.latestRelease)
                    }
                }
                Text("IceShot 自身不联网，不会自动检查更新；新版本请到发布页下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("隐私") {
                Text("截图默认只在本机处理，不会上传。历史记录保存在本机，可在「历史记录」页关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 通用

    /// 界面语言。
    ///
    /// 切换后必须重启：macOS 在进程启动时解析 `.lproj`，运行中改写 `AppleLanguages`
    /// 不会刷新已加载的字符串表。所以这里不假装热更新，而是直接明说并给重启按钮。
    @ViewBuilder
    private var languagePicker: some View {
        Picker("界面语言", selection: $languageChoice) {
            ForEach(LanguagePreferences.Choice.allCases) { choice in
                Text(choice.displayName).tag(choice)
            }
        }

        if languageNeedsRestart {
            HStack {
                Text("界面语言将变为「\(languageChoice.displayName)」，需要重启 IceShot 才会生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("立即重启") {
                    AppRelauncher.relaunch()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else {
            Text("跟随系统时会使用 macOS「语言与地区」里的设置；也可在「系统设置 > 通用 > 语言与地区 > 应用程序」里单独指定 IceShot 的语言。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 「通用」页的两组：界面语言、开机自启动。
    ///
    /// 不合成一个 `Section("通用")`：那个标题会和 tab 名重复，
    /// 而这两个开关本来就属于不同的事情（改界面 vs 改启动行为）。
    @ViewBuilder
    private var generalSection: some View {
        Section("界面语言") {
            languagePicker
        }

        Section("启动") {
            Toggle(
                String(localized: "开机时自动启动"),
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

    // MARK: - 动作

    /// 链接只在用户点击时交给系统浏览器，App 自身不发任何网络请求。
    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
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
            return hotkeys?.label(for: hotkey) ?? String(localized: "未设置")
        }
        let modifiers = recorder.pressedModifiers.symbol
        return modifiers.isEmpty ? "按下组合键…" : "\(modifiers)…"
    }
}
