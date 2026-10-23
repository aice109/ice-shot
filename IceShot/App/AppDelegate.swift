import AppKit
import SwiftData

/// 应用级依赖装配与生命周期入口。
///
/// 统一创建截图协调器、快捷键、历史库与编辑器，并负责：
/// - 启动时的屏幕录制权限预检与引导；
/// - Dock 图标的按需显示 / 隐藏；
/// - 测试宿主下跳过欢迎弹窗与全局快捷键注册。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: CaptureCoordinator
    let hotkeys: GlobalHotkeyManager
    let editor: EditorCoordinator
    let pins: PinBoard
    /// 应用级短反馈（复制 / 保存 / 取字复制条码…）：跨窗口共用一条通道。
    let feedback: FeedbackHUDController
    /// 更新检查：启动与菜单栏面板打开时调用，状态也被设置页读取。
    let updates: UpdateChecker
    let modelContainer: ModelContainer?
    let library: LibraryStore?
    let startupError: String?

    /// 有常规窗口时显示 Dock 图标，全部关闭后回到菜单栏形态。
    /// 测试宿主标记：测试也会启动 App，不能弹欢迎框、注册快捷键或联网检查更新。
    private let isTestHost: Bool
    private var activationPolicy: ActivationPolicyController?
    private var permissionOnboarding: PermissionOnboardingWindowController?
    private var observers: [NSObjectProtocol] = []

    override init() {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.isTestHost = isTestHost

        var runtime: LibraryRuntime?
        var startupError: String?
        do {
            runtime = try LibraryRuntimeFactory.make(inMemory: isTestHost)
        } catch {
            startupError = (error as? LocalizedError)?.errorDescription
                ?? "历史库初始化失败。"
        }

        let pins = PinBoard()
        let feedback = FeedbackHUDController()
        let editor = EditorCoordinator(
            pins: pins,
            feedback: feedback,
            library: runtime?.store
        )
        let coordinator = CaptureCoordinator(
            history: runtime?.store,
            pins: pins,
            editor: editor,
            feedback: feedback
        )
        self.coordinator = coordinator
        self.hotkeys = GlobalHotkeyManager(coordinator: coordinator)
        self.editor = editor
        self.pins = pins
        self.feedback = feedback
        // 应用内下载写沙盒临时目录，由历史库的路径布局提供；拿不到路径时
        // 不传下载器，界面自然只保留网页下载。
        let downloader: (any UpdateDownloading)? = runtime.map {
            URLSessionUpdateDownloader(tempDirectory: $0.paths.tempDirectory)
        }
        self.updates = UpdateChecker(
            presenter: AlertUpdatePresenter(),
            downloader: downloader
        )
        self.modelContainer = runtime?.container
        self.library = runtime?.store
        self.startupError = startupError
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 测试宿主也会启动 App；不要在测试时弹欢迎框或注册全局快捷键。
        guard !isTestHost else {
            return
        }

        hotkeys.registerConfiguredHotkeys()
        activationPolicy = ActivationPolicyController()
        permissionOnboarding = PermissionOnboardingWindowController(
            coordinator: coordinator,
            hotkeys: hotkeys
        )
        observePermissionOnboardingRequests()

        if let library {
            Task {
                await library.performMaintenance()
            }
        }

        presentStartupGuidance()
        // 启动也是检查点之一（另一处是菜单栏面板打开）；两者共用 24 小时节流。
        //
        // 不能直接同步调：`presentStartupGuidance()` 可能弹出模态的权限引导窗口，
        // 把人挡在外面；而 `NSAlert.runModal()` 也需要 App 已完成启动、激活策略就绪。
        // 推到下一轮 RunLoop 再查，此时启动引导已经稳定下来。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            updates.checkIfDue()
        }
    }

    /// 未授权时先弹权限引导窗口；已授权且首次启动时再说明应用在菜单栏。
    private func presentStartupGuidance() {
        let key = "hasSeenMenuBarWelcome"
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: key)
        if isFirstLaunch {
            UserDefaults.standard.set(true, forKey: key)
        }

        coordinator.refreshPermission()
        guard coordinator.permissionStatus != .authorized else {
            if isFirstLaunch {
                presentWelcomeAlert()
            }
            return
        }
        permissionOnboarding?.show(firstLaunch: isFirstLaunch)
    }

    private func presentWelcomeAlert() {
        NSApplication.shared.activate()

        let hotkeyHints = [
            (GlobalHotkeyManager.Hotkey.region, "区域"),
            (.window, "窗口"),
            (.fullScreen, "全屏"),
            (.repeatRegion, "重复上次区域"),
        ].compactMap { hotkey, name in
            hotkeys.binding(for: hotkey).map { "\($0.displayString) \(name)" }
        }
        let hotkeyLine = hotkeyHints.isEmpty
            ? "从菜单栏的 IceShot 图标选择截图动作。"
            : "可从菜单栏的 IceShot 图标开始，或使用 \(hotkeyHints.joined(separator: " / ")) 截图。"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "IceShot 已在菜单栏运行"
        alert.informativeText = """
        \(hotkeyLine)
        截图会保存到本机历史库，可在菜单栏打开「历史记录」查看。
        快捷键可在「设置 → 全局快捷键」中录制、清除或恢复默认。
        截图只在本机处理，不会上传；首次截图时系统会请求屏幕录制权限。
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    /// 菜单栏入口与截图失败路径都可能需要重新打开引导窗口。
    private func observePermissionOnboardingRequests() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .iceShotShowPermissionOnboarding,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.permissionOnboarding?.show()
                }
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        coordinator.cancelCurrentSelection()
        hotkeys.unregisterAll()
    }

    /// 从「系统设置」切回来时立刻重新预检屏幕录制权限，避免界面一直停留在旧状态。
    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.refreshPermission()
    }
}
