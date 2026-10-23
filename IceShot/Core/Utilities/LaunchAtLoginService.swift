import Foundation
import ServiceManagement

/// 开机自启动的**系统**状态。
///
/// 为什么不学其它开关存 `@AppStorage`：真实状态只有系统知道，用户随时可能在
/// 「系统设置 > 通用 > 登录项」里手动关掉、或者在 App 被移动 / 未批准时失效。
/// 界面每次展示都以系统状态为准，本地不存第二份真相。
///
/// 各状态在本机的实测语义（macOS 27，用同签名同沙盒配置的探针验证）：
///
/// | `SMAppService.Status` | 含义 |
/// | --- | --- |
/// | `.enabled` | 已注册且已启用 |
/// | `.notRegistered` | 注册过、又被注销（系统里留着墓碑） |
/// | `.notFound` | **还没注册过**：全新安装第一次就是它，不是「App 不见了」 |
/// | `.requiresApproval` | 已注册，但用户在系统设置里关掉了 |
enum LaunchAtLoginState: Equatable {
    /// 已注册且系统已启用。
    case enabled
    /// 未启用：注册过又注销，或者还从未注册过。
    case disabled
    /// 已注册，但用户在系统设置里关掉了，需要用户去批准。
    case requiresApproval

    var isEnabled: Bool { self == .enabled }
}

/// 登录项能力的抽象。
///
/// `SMAppService` 在测试进程里无法真正注册登录项（会弹系统提示 / 依赖真实的 App 包），
/// 所以抽一层协议，单测用假实现验证「状态映射 + 失败回滚 + 文案」这些纯逻辑。
@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var state: LaunchAtLoginState { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// `SMAppService.mainApp` 实现。
///
/// 用 `.mainApp` 而不是自建 LaunchAgent：不需要额外 plist，沙盒里可用，
/// 也不需要新 entitlement，且由系统负责「登录项」列表里的展示与批准流程。
@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    private var service: SMAppService { SMAppService.mainApp }

    var state: LaunchAtLoginState {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            // `.notFound` 是「还没有记录」，全新安装第一次就是它；
            // 两者对用户都是「未启用」，不能当成错误提示。
            return .disabled
        @unknown default:
            // 系统加了新状态时不猜语义：当作未启用，交给用户操作时再暴露错误。
            return .disabled
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
