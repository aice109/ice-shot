import AppKit

/// 屏幕录制等 TCC 权限授予后，系统只会在**下次启动**时生效。
/// 这里负责以新实例重新打开自己，然后退出当前进程。
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            NSApplication.shared.terminate(nil)
        }
    }
}
