import AppKit
import CoreGraphics

/// 操作条上的动作：浮层与编辑器窗口各自接到自己的实现上。
///
/// 两个入口的**按钮与文案完全一样**，但「复制」在浮层里是「复制并关闭这次截图」、
/// 在编辑器窗口里是「复制到剪贴板、窗口留着继续改」。所以动作不写在视图里，
/// 而是由宿主注入，避免两边各写一套按钮又把文案写偏。
@MainActor
struct MarkupActions {
    var copy: () -> Void
    var save: () -> Void
    var pin: () -> Void
    /// 关闭 / 结束本次编辑；编辑器窗口不显示这个按钮，也就不需要实现。
    var close: () -> Void = {}
    /// 旋转 / 翻转（只给编辑器窗口用）。
    var transform: (MarkupToolbarLayout.Transform) -> Void = { _ in }

    init(
        copy: @escaping () -> Void,
        save: @escaping () -> Void,
        pin: @escaping () -> Void,
        close: @escaping () -> Void = {},
        transform: @escaping (MarkupToolbarLayout.Transform) -> Void = { _ in }
    ) {
        self.copy = copy
        self.save = save
        self.pin = pin
        self.close = close
        self.transform = transform
    }
}

/// 在编辑器窗口里完成「复制 / 保存 / 贴图」的公共实现。
///
/// 与截取浮层（`SelectionOverlayController`）走同一套导出：`renderedImage()` 取带标注的结果，
/// 复制走 `ClipboardWriter`、保存走 `SavePanel`、贴图走 `PinBoard`。
/// 失败一律交给调用方的 `onError` 弹原生提示，不静默。
@MainActor
enum MarkupOutput {
    static func copy(_ image: CGImage) throws -> String {
        try ClipboardWriter().copy(image)
        return String(localized: "已复制到剪贴板")
    }

    /// 返回 `nil` 表示用户在保存面板里取消了。
    static func save(_ image: CGImage) throws -> String? {
        try SavePanel.savePNG(image) ? String(localized: "已保存") : nil
    }
}
