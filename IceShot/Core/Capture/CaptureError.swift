import Foundation

/// 截图链路的结构化错误。
///
/// 权限拒绝、显示器变化、窗口消失、编码 / 写入失败必须分开表达，
/// 这样 UI 才能给出可执行的下一步（去授权 / 重选窗口 / 检查磁盘），
/// 而不是一律提示「截图失败」。
///
/// 标记 `nonisolated`：纯 Core 类型（如 `ScreenshotFrameComposer`）会在非主 actor 上抛它。
nonisolated enum CaptureError: LocalizedError, Sendable {
    /// 屏幕录制权限被拒绝或尚未生效。
    case permissionDenied
    case noDisplays
    case displayUnavailable
    case noWindows
    case windowUnavailable
    case captureFailed(code: Int)
    /// 抓到的帧几乎没有可见内容（系统 overlay 或窗口已不可截）。
    case captureBlank
    case invalidSelection
    case encodingFailed
    case saveFailed(code: Int)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "需要屏幕录制权限。请在系统设置中允许 IceShot 录制屏幕。")
        case .noDisplays:
            return String(localized: "没有找到可用的显示器。")
        case .displayUnavailable:
            return String(localized: "显示器不可用，请检查连接后重试。")
        case .noWindows:
            return String(localized: "没有找到可截取的窗口。请先打开一个窗口，或改用区域截图。")
        case .windowUnavailable:
            return String(localized: "窗口已关闭或不可用，请重新选择。")
        case .captureFailed(let code):
            return "截图失败（错误码 \(code)）。请重试。"
        case .captureBlank:
            return String(localized: "这扇窗口没有可截取的内容，请改用区域框选。")
        case .invalidSelection:
            return String(localized: "选区无效，请重新选择。")
        case .encodingFailed:
            return String(localized: "图片编码失败。")
        case .saveFailed(let code):
            return "保存失败（错误码 \(code)）。请检查磁盘空间或权限。"
        }
    }
}
