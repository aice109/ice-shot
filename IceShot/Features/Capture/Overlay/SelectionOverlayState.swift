import CoreGraphics
import Observation

/// 多屏浮层共享的选区状态。
///
/// 同一时间只允许一个显示器有选区；在另一块屏幕开始拖拽时，旧选区自动清空。
/// 选区确定后进入编辑阶段，选区锁定，标注由共享的 `EditorModel` 持有。
@MainActor
@Observable
final class SelectionOverlayState {
    private(set) var activeDisplayID: CGDirectDisplayID?
    private(set) var rect: CGRect = .zero
    private(set) var isSpacePressed = false
    private(set) var isEditing = false
    private(set) var editor: EditorModel?
    /// 模型图在显示器局部坐标中的位置（points）。
    ///
    /// 区域截图用整个冻结帧作为模型图（选区只是它的可视窗口），因此可以在编辑态继续
    /// 调整选区而不丢标注；窗口 / 全屏 / 重复区域用预设图像，选区锁定。
    private(set) var editorImageFrame: CGRect = .zero
    /// 编辑态是否还允许调整选区（区域截图保留手柄 / 方向键 / Space 拖移）。
    private(set) var allowsAdjustment = false

    /// 未框选时悬停高亮的窗口（多屏共享，同一时间只有一处）。
    private let hover = WindowHoverState()

    /// 当前高亮的窗口；框选 / 编辑态下视图不再展示它。
    var hoveredWindowID: CGWindowID? {
        hover.windowID
    }

    /// 高亮所在显示器：其它屏据此判断「这个高亮不是我的」。
    var hoveredDisplayID: CGDirectDisplayID? {
        hover.displayID
    }

    func updateHover(windowID: CGWindowID?, displayID: CGDirectDisplayID) {
        hover.update(windowID: windowID, displayID: displayID)
    }

    func clearHover(displayID: CGDirectDisplayID) {
        hover.clear(displayID: displayID)
    }

    func selection(for displayID: CGDirectDisplayID) -> CGRect {
        activeDisplayID == displayID ? rect : .zero
    }

    func update(displayID: CGDirectDisplayID, rect: CGRect) {
        activeDisplayID = displayID
        self.rect = rect
    }

    func clear(displayID: CGDirectDisplayID) {
        guard activeDisplayID == displayID else { return }
        activeDisplayID = nil
        rect = .zero
        endEditing()
    }

    func beginEditing(
        editor: EditorModel,
        imageFrame: CGRect,
        allowsAdjustment: Bool
    ) {
        self.editor = editor
        self.editorImageFrame = imageFrame
        self.allowsAdjustment = allowsAdjustment
        isEditing = true
    }

    func endEditing() {
        isEditing = false
        editor = nil
        editorImageFrame = .zero
        allowsAdjustment = false
    }

    func setSpacePressed(_ pressed: Bool) {
        // 值不变就不赋值。
        //
        // `isSpacePressed` 是 `@Observable` 属性，无条件赋值会通知所有观察者，
        // 整块浮层重建一遍；长按 Space 时 keyDown 会反复派发，于是重建风暴。
        // 重建本身不该发声，但它会反复取消/恢复焦点与点击区，很容易连带着
        // 触发系统提示音。这里按值去重，从源头上少掉这堆无效通知。
        guard isSpacePressed != pressed else { return }
        isSpacePressed = pressed
    }

    // MARK: - 指针位置

    /// 指针在各显示器局部坐标里的最新位置（左上原点）。
    ///
    /// 由面板级鼠标移动监视器写入，**不依赖 SwiftUI 的 hover 回调**——
    /// 后者的追踪区只跟着具体子视图走，指针停在手柄 / 工具条上时父层收不到事件，
    /// 光标就会卡住不跟手。视图直接观察这个值重算光标。
    private(set) var pointerByDisplay: [CGDirectDisplayID: CGPoint] = [:]

    func updatePointer(_ point: CGPoint?, displayID: CGDirectDisplayID) {
        if let point {
            pointerByDisplay[displayID] = point
        } else if pointerByDisplay[displayID] != nil {
            pointerByDisplay.removeValue(forKey: displayID)
        }
    }

    func pointer(for displayID: CGDirectDisplayID) -> CGPoint? {
        pointerByDisplay[displayID]
    }
}
