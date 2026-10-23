import CoreGraphics
import Observation

/// 多屏共享的窗口悬停状态。
///
/// 窗口选择模式与合并后的框选浮层都会悬停高亮窗口；同一时间只允许一处高亮，
/// 因此状态集中在这里，由各屏视图比较 `displayID` 判断「当前高亮是不是我」。
@MainActor
@Observable
final class WindowHoverState {
    private(set) var windowID: CGWindowID?
    private(set) var displayID: CGDirectDisplayID?

    /// 更新悬停窗口；`displayID` 用于其它屏幕判断「当前高亮是否属于我」。
    func update(windowID: CGWindowID?, displayID: CGDirectDisplayID) {
        self.windowID = windowID
        self.displayID = displayID
    }

    /// 指针离开某块屏幕时清除高亮，但不会误伤另一块屏幕的悬停状态。
    func clear(displayID: CGDirectDisplayID) {
        guard self.displayID == displayID else { return }
        windowID = nil
        self.displayID = nil
    }

    func clearAll() {
        windowID = nil
        displayID = nil
    }
}
