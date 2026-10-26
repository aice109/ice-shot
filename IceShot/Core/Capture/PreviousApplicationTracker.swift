import AppKit

/// 记住最近一个不属于 IceShot 的前台 App。
///
/// 截取流程只能在启动瞬间看一次 `NSWorkspace.frontmostApplication`，而入口经常是
/// 菜单栏面板——面板本身就是 IceShot 的窗口，那一刻拿到的「前台」是 IceShot 自己。
/// 长截图结束时必须把前台还给用户真正要滚动的那个 App：台前调度（Stage Manager）
/// 会把非前台 App 的窗口挪下舞台，还错了人，连续抓取到的就只有桌面。
@MainActor
final class PreviousApplicationTracker {
    private(set) var application: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                let activated = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.record(activated)
            }
        }
        record(NSWorkspace.shared.frontmostApplication)
    }

    /// 最近一个外部前台 App；已经退出时返回 nil，让调用方退回当前前台。
    var lastExternalApplication: NSRunningApplication? {
        guard let application, !application.isTerminated else { return nil }
        return application
    }

    private func record(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else {
            return
        }
        self.application = application
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
