import AppKit
import SwiftUI

/// 菜单栏面板：一眼看到权限状态 + 截图入口 + 历史 / 设置。
///
/// 只用原生 `Button` / `Menu` / `Divider`，背景材质交给系统的
/// `MenuBarExtra` 窗口，不手绘卡片与 hover 效果。
struct MenuBarView: View {
    let coordinator: CaptureCoordinator
    let hotkeys: GlobalHotkeyManager?
    let library: LibraryStore?
    let pins: PinBoard?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusSection
            Divider()
            captureSection
            Divider()
            librarySection
            if let pins, !pins.isEmpty {
                Divider()
                pinsSection(pins)
            }
            // 只有开着取证开关、且确实写过诊断文件时才出现，平时不占版面。
            if HangTrace.isEnabled, HangTrace.hasDiagnostics {
                Divider()
                diagnosticsSection
            }
            Divider()
            footer
        }
        .padding(14)
        // 英文文案普遍比中文长 1.5～2 倍（「全屏截图」→ "Full Screen Capture"），
        // 320 pt 会把标题椭掉。按当前运行语言给宽度：中文紧凑、英文宽松。
        .frame(width: Self.panelWidth)
        .onAppear {
            coordinator.refreshPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: .iceShotDismissMenuBarPanel)) { _ in
            closeMenuBarPanel()
        }
    }

    // MARK: - 头部

    /// 面板宽度按**当前生效**的界面语言取。
    ///
    /// 截图按钮与底部工具行都带文字（「全屏截图」→ "Full Screen Capture"、
    /// 「获取新版本…」→ "Get New Version…"），英文比中文长得多，要给更宽的容器。
    /// 用 `Bundle.main` 而不是系统语言：用户可能把 IceShot 单独指定成英文而系统是中文，
    /// 那时按系统语言算宽度就会截断。
    /// 列表行的统一内边距：`Menu` 与 `Button` 的标签都没有默认内边距，
    /// 两处共用同一组值才不会一高一矮。
    private static let rowHorizontalPadding: CGFloat = 10
    private static let rowVerticalPadding: CGFloat = 5

    private static var panelWidth: CGFloat {
        let isEnglish = Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false
        return isEnglish ? 380 : 320
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("IceShot")
                        .font(.headline)
                    if let tag = AppVersion.channel.tag {
                        // 预览版标识：用系统材质胶囊，不手绘边框
                        Text(tag)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .accessibilityLabel("预览版")
                    }
                }
                Text("截图只在本机处理，不会上传")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if coordinator.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在截图")
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: permissionSymbol)
                    .foregroundStyle(permissionTint)
                    .accessibilityHidden(true)
                Text(coordinator.permissionSummary)
                    .font(.caption)
                Spacer(minLength: 0)
            }

            if let message = coordinator.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let message) = coordinator.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = hotkeys?.registrationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.permissionStatus != .authorized {
                HStack(spacing: 8) {
                    Button("授予屏幕录制权限…") {
                        openPermissionOnboarding()
                    }
                    Button("打开系统设置") {
                        coordinator.openPermissionSettings()
                    }
                    Button("重新检查") {
                        coordinator.refreshPermission()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("授权后需要重启 IceShot 才生效。系统设置列表里没有 IceShot 时，先点「授予屏幕录制权限…」。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionSymbol: String {
        switch coordinator.permissionStatus {
        case .authorized: return "checkmark.shield.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .notDetermined: return "shield"
        }
    }

    private var permissionTint: Color {
        switch coordinator.permissionStatus {
        case .authorized: return .green
        case .denied: return .orange
        case .notDetermined: return .secondary
        }
    }

    // MARK: - 截图

    private var captureSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    startCapture {
                        await coordinator.startRegionCapture(delay: .milliseconds(250))
                    }
                } label: {
                    actionLabel("区域截图", symbol: "rectangle.dashed", shortcut: shortcutLabel(.region))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("拖拽框选区域，或直接点击高亮的窗口")

                // 延时是「区域截图」的修饰动作，紧跟主按钮，不再单独占一行。
                Menu {
                    delayItems(for: String(localized: "区域")) { startDelayedRegion(seconds: $0) }
                    Divider()
                    delayItems(for: String(localized: "全屏")) { startDelayedFullScreen(seconds: $0) }
                    Divider()
                    delayItems(for: String(localized: "窗口")) { startDelayedWindow(seconds: $0) }
                    Divider()
                    delayItems(for: String(localized: "全部显示器")) { startDelayedAllDisplays(seconds: $0) }
                } label: {
                    Image(systemName: "timer")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("延时截图：3 / 5 / 10 秒后自动开始，倒计时期间可取消")
                .accessibilityLabel("延时截图")
            }

            // 五个动作排成单列竖表，不再用两列 `Grid`。
            //
            // 原来是 2×3 网格，但英文放不下：`Full Screen Capture` 加上右侧快捷键
            // 需要 195pt，而 380pt 面板的两列每格只有 172pt，实测超出 22pt。
            // 菜单栏面板本来就是窄容器，单列列表也比网格更常见：
            // 每行右侧对齐快捷键，左侧文案长短自由，两种语言都不截断。
            VStack(spacing: 8) {
                Button {
                    startCapture {
                        await coordinator.startWindowCapture(delay: .milliseconds(250))
                    }
                } label: {
                    actionLabel("窗口截图", symbol: "macwindow", shortcut: shortcutLabel(.window))
                }
                .help("悬停并点击一个窗口")

                Button {
                    startCapture {
                        await coordinator.startFullScreenCapture(delay: .milliseconds(250))
                    }
                } label: {
                    actionLabel("全屏截图", symbol: "rectangle.inset.filled", shortcut: shortcutLabel(.fullScreen))
                }
                .help("截取光标所在的显示器")

                Button {
                    startCapture {
                        await coordinator.startAllDisplaysCapture(delay: .milliseconds(250))
                    }
                } label: {
                    actionLabel("全部显示器", symbol: "rectangle.on.rectangle", shortcut: nil)
                }
                .help("逐屏截取所有显示器")

                Button {
                    startCapture {
                        await coordinator.startRepeatLastRegion(delay: .milliseconds(250))
                    }
                } label: {
                    actionLabel("重复上次", symbol: "arrow.counterclockwise", shortcut: shortcutLabel(.repeatRegion))
                }
                .help("复用上次区域；显示器或分辨率变化时回退到区域选择")

                Button {
                    startCapture {
                        await coordinator.startScrollCapture(delay: .milliseconds(250))
                    }
                } label: {
                    actionLabel("长截图", symbol: "scroll", shortcut: shortcutLabel(.scroll))
                }
                .help("框选后自己滚动内容，自动拼接成一张长图")
            }
            .buttonStyle(.bordered)
        }
        .disabled(coordinator.isBusy)
    }

    /// 菜单栏面板里的快捷键提示跟随用户配置；清除后不再显示。
    private func shortcutLabel(_ hotkey: GlobalHotkeyManager.Hotkey) -> String? {
        hotkeys?.binding(for: hotkey)?.displayString
    }

    @ViewBuilder
    private func delayItems(
        for title: String,
        action: @escaping (Int) -> Void
    ) -> some View {
        ForEach([3, 5, 10], id: \.self) { value in
            Button("\(title) · \(value) 秒") {
                action(value)
            }
        }
    }

    /// 截图按钮的标题 + 右侧快捷键。
    ///
    /// 标题走 `LocalizedStringKey`：英文文案普遍比中文长（「区域截图」→ "Region Capture"），
    /// 所以标题给 `lineLimit(1)` 并允许它比快捷键占更多宽度；
    /// 快捷键固定宽度、不参与压缩，否则先被椭掉的一定是它。
    private func actionLabel(
        _ title: LocalizedStringKey,
        symbol: String,
        shortcut: String?
    ) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if let shortcut {
                Text(shortcut)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 历史 / 设置 / 退出

    private var librarySection: some View {
        Button {
            openLibrary()
        } label: {
            HStack(spacing: 6) {
                Label("历史记录", systemImage: "photo.stack")
                Spacer(minLength: 0)
                Text("⌘O")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // 与 `pinsSection` 用同一套内边距 / 高度：两者上下相邻，
            // 任何一侧多出几 pt 都会让整列看起来错位。
            .padding(.horizontal, Self.rowHorizontalPadding)
            .padding(.vertical, Self.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(library == nil)
        .help("查看本机保存的截图")
    }

    /// 贴图管理：穿透后的贴图收不到鼠标事件，只能从这里恢复交互或关闭。
    private func pinsSection(_ pins: PinBoard) -> some View {
        Menu {
            ForEach(pins.pins) { pin in
                Menu(pin.isClickThrough ? "\(pin.name)（已穿透）" : pin.name) {
                    Button("复制") { pin.copyToPasteboard() }
                    Button("恢复原始大小与不透明度") { pin.resetPresentation() }
                    Button("恢复交互") { pin.setClickThrough(false) }
                        .disabled(!pin.isClickThrough)
                    Divider()
                    Button("关闭") { pins.close(pin) }
                }
            }
            Divider()
            Button("恢复全部交互") { pins.restoreInteraction() }
                .disabled(!pins.hasClickThroughPin)
            Button("关闭全部贴图") { pins.closeAll() }
        } label: {
            HStack(spacing: 6) {
                Label("贴图", systemImage: "pin")
                Spacer(minLength: 0)
                Text("\(pins.count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // 与「历史记录」逐像素对齐：同样的内边距与最小高度。
            //
            // 之前这里只有 `.frame(maxWidth: .infinity)`：`Menu` 的标签不像 `Button`
            // 那样自带内边距与最小高度，于是它比上下的按钮矮一截、文字贴边，
            // 一有贴图整块面板的节奏就乱了。
            .padding(.horizontal, Self.rowHorizontalPadding)
            .padding(.vertical, Self.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .disabled(pins.isEmpty)
        .help("管理屏幕上的贴图")
    }

    /// 卡死取证文件的导出入口。
    ///
    /// 只在本机确实写过诊断文件时出现（`HangTrace.hasDiagnostics`），平时不占版面。
    /// 之所以必须有这个按钮：沙盒 App 的诊断文件落在容器里，而容器受 macOS 隐私保护，
    /// 用户在自己的终端里 `ls` 只会得到 `Operation not permitted`。
    /// 让用户亲手选一个目录导出，是唯一不需要任何系统权限、也不需要敲命令的取回方式。
    private var diagnosticsSection: some View {
        Button {
            exportDiagnostics()
        } label: {
            Label("导出卡死日志…", systemImage: "stethoscope")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .help("把诊断文件保存到你选择的文件夹，用于排查卡死（不含截图内容）")
    }

    /// 让用户选目录，再把诊断文件拷过去。
    private func exportDiagnostics() {
        closeMenuBarPanel()

        let panel = NSOpenPanel()
        panel.title = String(localized: "导出卡死日志")
        panel.message = String(localized: "选择一个文件夹用于保存诊断文件")
        panel.prompt = String(localized: "导出")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            let written = try HangTrace.export(to: directory)
            guard !written.isEmpty else {
                presentDiagnosticsAlert(
                    message: String(localized: "没有可导出的诊断文件"),
                    detail: String(localized: "先复现一次卡死，或直接用屏幕截图工具把现象拍下来。")
                )
                return
            }
            presentDiagnosticsAlert(
                message: String(localized: "已导出诊断文件"),
                detail: "已保存到：\(directory.path)\n\n" + written.joined(separator: "\n")
            )
        } catch {
            presentDiagnosticsAlert(
                message: String(localized: "导出失败"),
                detail: (error as? LocalizedError)?.errorDescription
                    ?? "错误码 \((error as NSError).code)"
            )
        }
    }

    private func presentDiagnosticsAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 面板底部：设置 / 获取新版本 / 退出，一行三个文字按钮。
    ///
    /// 这是菜单栏面板最常见的形式，也跟本面板其它按钮同一套外观：
    /// 三个都是「面板级操作」、彼此平级，用同样的 `.bordered` 排成整齐一行。
    ///
    /// 早前试过两个方向，都不如这个：
    /// - 纯图标：齿轮和电源认得，但「获取新版本」的箭头方框语焉不详；
    /// - 图标 + 文字混排：两个图标一个文字，视觉不成组，怎么摆都不齐。
    ///
    /// **不用等宽**：三个按钮按各自内容取宽、整行居中。等宽会让
    /// 「获取新版本…」这种长文案被迫缩字（实测中文要 107%、英文 135% 的宽度），
    /// 反而更难读；按内容取宽则每个按钮都是自然大小，视觉重量由文案长度自然体现。
    private var footer: some View {
        HStack(spacing: 8) {
            footerButton(
                title: "设置…",
                symbol: "gearshape",
                help: "打开设置（⌘,）"
            ) {
                openSettingsWindow()
            }

            footerButton(
                title: "获取新版本…",
                symbol: "arrow.up.right.square",
                help: "在浏览器里打开最新版本的发布页（IceShot 自身不联网）"
            ) {
                closeMenuBarPanel()
                NSWorkspace.shared.open(ProjectLinks.latestRelease)
            }

            footerButton(
                title: "退出",
                symbol: "power",
                help: "退出 IceShot"
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        // 整行居中：三个按钮自然宽度之和在面板里居中，
        // 两侧留白相等，读起来是一个完整的工具行。
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 底部的一个文字按钮：按自身内容取宽，不参与压缩。
    private func footerButton(
        title: LocalizedStringKey,
        symbol: String,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help(help)
        .accessibilityLabel(title)
    }

    // MARK: - 动作

    private func openLibrary() {
        closeMenuBarPanel()
        openWindow(id: "library")
        NSApplication.shared.activate()
    }

    private func openSettingsWindow() {
        // 先收面板再开窗：面板关闭会触发激活策略复查，
        // 交给 `SettingsWindowPresenter` 统一保证「先切 .regular、再显示、再激活」。
        closeMenuBarPanel()
        SettingsWindowPresenter.present { openSettings() }
    }

    private func startCapture(_ action: @escaping () async -> Void) {
        closeMenuBarPanel()
        Task {
            await action()
        }
    }

    private func startDelayedRegion(seconds: Int) {
        startCapture {
            await coordinator.startRegionCapture(
                delay: .milliseconds(250),
                countdownSeconds: seconds
            )
        }
    }

    private func startDelayedFullScreen(seconds: Int) {
        startCapture {
            await coordinator.startFullScreenCapture(
                delay: .milliseconds(250),
                countdownSeconds: seconds
            )
        }
    }

    private func startDelayedWindow(seconds: Int) {
        startCapture {
            await coordinator.startWindowCapture(
                delay: .milliseconds(250),
                countdownSeconds: seconds
            )
        }
    }

    private func startDelayedAllDisplays(seconds: Int) {
        startCapture {
            await coordinator.startAllDisplaysCapture(
                delay: .milliseconds(250),
                countdownSeconds: seconds
            )
        }
    }

    private func openPermissionOnboarding() {
        closeMenuBarPanel()
        NotificationCenter.default.post(name: .iceShotShowPermissionOnboarding, object: nil)
    }

    private func closeMenuBarPanel() {
        dismiss()
        guard let keyWindow = NSApplication.shared.keyWindow,
              keyWindow is NSPanel,
              keyWindow.level.rawValue >= NSWindow.Level.statusBar.rawValue else {
            return
        }
        keyWindow.orderOut(nil)
    }
}
