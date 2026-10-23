import AppKit
import CoreGraphics

enum ScreenRecordingPermissionStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

@MainActor
protocol ScreenRecordingPermissionChecking {
    func status() -> ScreenRecordingPermissionStatus
    func request() async -> ScreenRecordingPermissionStatus
    func openSystemSettings()
}

/// 屏幕录制权限的预检、申请与系统设置引导。
///
/// 不读取 TCC 数据库；`CGPreflight` 只能告诉我们当前是否已授权，
/// 因此用 UserDefaults 记录「是否主动申请过」来区分未申请与已拒绝——这个标记
/// **只用于文案**，不再决定是否发起申请。
@MainActor
final class ScreenRecordingPermission: ScreenRecordingPermissionChecking {
    private let requestedKey = "hasRequestedScreenRecordingAccess"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func status() -> ScreenRecordingPermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        return defaults.bool(forKey: requestedKey) ? .denied : .notDetermined
    }

    /// 未授权时总是向系统发起一次申请。
    ///
    /// `CGRequestScreenCaptureAccess()` 只有在「系统里还没有本应用的记录」时弹窗；
    /// 已有记录（无论允许还是拒绝）时只会同步返回当前结果，因此重复调用是安全的。
    ///
    /// 必须每次都调用、而不是只看本地标记：系统只在「还没有本应用记录」时弹窗，
    /// 已授权时调用是安全的空操作。若沿用「申请过就早退」的本地逻辑，
    /// 证书更换或用户手动从列表里删掉 IceShot 后，系统既不会弹窗、也不会把应用
    /// 重新登记进「屏幕与系统音频录制」列表，用户只能手动点 `+` 添加。
    func request() async -> ScreenRecordingPermissionStatus {
        guard status() != .authorized else {
            return .authorized
        }

        defaults.set(true, forKey: requestedKey)
        _ = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        return status()
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        _ = NSWorkspace.shared.open(url)
    }
}
