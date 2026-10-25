import Foundation
import Observation

/// 设置页「开机时自动启动」的状态机。
///
/// 职责边界：
/// - 开关值永远读系统的登录项状态，不在本地存布尔；
/// - 开启 / 关闭失败时**回滚**（重新读系统状态）并把原因交给界面展示，不静默成功；
/// - 用户可能在系统设置里改登录项，所以窗口每次获得焦点都要 `refresh()`。
@MainActor
@Observable
final class LaunchAtLoginModel {
    private let service: LaunchAtLoginServicing
    /// 当前 App 的实际路径：只有「从 DMG / 下载目录直接跑」才需要提示，普通首启不该提示。
    private let bundlePath: String

    private(set) var state: LaunchAtLoginState
    /// 最近一次操作的失败原因；下次成功操作或刷新时清空。
    private(set) var failureMessage: String?

    // 默认参数不能写成 `LaunchAtLoginService()`：默认参数在非隔离上下文求值，
    // 而服务是 `@MainActor` 的；用 `nil` 占位，实际实例在 init 体内创建。
    init(service: (any LaunchAtLoginServicing)? = nil, bundlePath: String? = nil) {
        let resolved = service ?? LaunchAtLoginService()
        self.service = resolved
        self.bundlePath = bundlePath ?? Bundle.main.bundleURL.path
        self.state = resolved.state
    }

    var isEnabled: Bool { state.isEnabled }

    /// 需要用户在系统设置里动手时的说明；不需要时返回 `nil`。
    ///
    /// 注意 `.disabled`（含「从未注册过」）**不算异常**：全新安装打开设置页时就是它，
    /// 这时候弹「系统找不到 App」纯属误导（0.2.1 的线上问题）。
    var systemHint: String? {
        switch state {
        case .requiresApproval:
            return String(localized: "系统里这个登录项被关掉了：到「系统设置 > 通用 > 登录项」重新打开 IceShot。")
        case .enabled, .disabled:
            return nil
        }
    }

    /// 从 DMG / 下载目录直接运行时的一次性说明。
    ///
    /// 这种情况注册登录项一定失败（系统不认临时挂载或 App Translocation 里的副本），
    /// 所以要提前讲清楚，而不是等 `register()` 抛一个用户看不懂的错。
    var locationHint: String? {
        if bundlePath.contains("/AppTranslocation/") {
            return String(localized: "当前是从下载目录直接打开的临时副本：先把 IceShot 拖到「应用程序」再打开，才能注册登录项。")
        }
        if bundlePath.hasPrefix("/Volumes/") {
            return String(localized: "当前正在从磁盘映像里运行：先把 IceShot 拖到「应用程序」再打开，才能注册登录项。")
        }
        return nil
    }

    /// 「打开登录项设置」按钮只在需要用户批准时出现。
    var showsSystemSettingsButton: Bool {
        state == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        failureMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failureMessage = "设置开机自启动失败：\(error.localizedDescription)（错误码 \((error as NSError).code)）"
        }
        // 无论成功失败都以系统状态为准：失败时这里就把开关拨回原样。
        refresh()
    }

    func refresh() {
        state = service.state
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
