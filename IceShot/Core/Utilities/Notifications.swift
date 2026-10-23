import Foundation

extension Notification.Name {
    /// 触发截图前关闭菜单栏面板，避免把面板截进静态帧。
    static let iceShotDismissMenuBarPanel = Notification.Name("IceShotDismissMenuBarPanel")

    /// 打开屏幕录制权限引导窗口（菜单栏入口与截图失败路径共用）。
    static let iceShotShowPermissionOnboarding = Notification.Name("IceShotShowPermissionOnboarding")
}
