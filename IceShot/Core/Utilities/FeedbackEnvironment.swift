import SwiftUI

/// 应用级短反馈（底部玻璃胶囊，1.4 s 自动消失）的 SwiftUI 入口。
///
/// 需求背景：同一次「复制成功」在浮层、编辑器、历史库里必须是同一个视觉反馈。
/// 之前取字模式在图像内部自绘了一条提示条——它与系统 Live Text 的 AppKit 图层挤在
/// 一个 `ZStack` 里，实测点了二维码内容复制成功但提示条不显示。与其在图层顺序里
/// 赌运气，不如统一走 `FeedbackHUDController`：独立的无边框面板，永远在最上层。
///
/// 注入点在三个宿主根视图（截取浮层 / 编辑器窗口 / 历史窗口）；
/// 由 `AppDelegate` 持有的同一个实例注入，保证跨窗口只有一条反馈通道。
private struct FeedbackHUDKey: EnvironmentKey {
    static var defaultValue: FeedbackHUDController? { nil }
}

extension EnvironmentValues {
    /// 为 nil 时表示当前宿主没有装配反馈面板（例如单元测试里的裸视图）。
    var feedbackHUD: FeedbackHUDController? {
        get { self[FeedbackHUDKey.self] }
        set { self[FeedbackHUDKey.self] = newValue }
    }
}

extension View {
    /// 装配反馈通道；`hud` 为 nil 时不产生任何副作用。
    func feedbackHUD(_ hud: FeedbackHUDController?) -> some View {
        environment(\.feedbackHUD, hud)
    }
}

extension Optional where Wrapped == FeedbackHUDController {
    /// 在无反馈通道时静默跳过，避免调用点到处写 `if let`。
    func show(_ message: String) {
        self?.show(message)
    }
}
