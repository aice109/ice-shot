import CoreGraphics

/// 浮层指针交互的纯判定：短位移算点击（截高亮窗口），超出阈值算拖拽（框选区域）。
///
/// 阈值取 3 pt：按下瞬间的手抖常见 1–2 px 位移，按点击处理更贴近系统截图的操作直觉；
/// 同时 3 pt 足够小，不会吞掉真实的框选。
enum PointerInteraction {
    /// 点击 / 拖拽的判定阈值（points）。
    static let clickTolerance: CGFloat = 3

    enum Kind: Equatable {
        case click
        case drag
    }

    static func kind(translation: CGSize) -> Kind {
        let distance = max(abs(translation.width), abs(translation.height))
        return distance < clickTolerance ? .click : .drag
    }

    /// 松手时到底算「点击截窗口」还是「完成框选」。
    ///
    /// 只看位移不够：框一个很小的目标（通知横幅、图标）时，起止位移同样可能
    /// 小于阈值，但那明明是一次框选。
    ///
    /// 也不能只看「有没有选区」：按下瞬间 `DragGesture` 就会把选区刷成一个
    /// 亚像素矩形（实测 `0.5 × 0.5`），它的宽高非零却不能截，
    /// 若当成选区会把单击停死——“点了没反应”。
    /// 所以判据是**选区是否达到可截取的最小尺寸**。
    static func kind(translation: CGSize, selectionSize: CGSize) -> Kind {
        guard isUsableSelection(selectionSize) else {
            return kind(translation: translation)
        }
        return .drag
    }

    /// 选区最小可截取边长（points），与裁剪入口的门槛保持一致。
    static let minimumSelectionSide: CGFloat = 1

    static func isUsableSelection(_ size: CGSize) -> Bool {
        size.width >= minimumSelectionSide && size.height >= minimumSelectionSide
    }
}

/// 悬停高亮的命中与几何：显示器局部点 → 窗口目录里最前面的窗口 → 显示用矩形。
///
/// 浮层拿到的是显示器局部点，窗口目录是全局 CG 坐标，所以换算统一放在这里，
/// 窗口选择模式与合并后的框选浮层共用同一套判定。
enum WindowHoverPicker {
    /// 命中光标下的窗口；`windows` 需按前到后排序。
    static func window(
        atLocalPoint point: CGPoint,
        display: DisplayDescriptor,
        windows: [WindowDescriptor]
    ) -> WindowDescriptor? {
        WindowFilter.hitTest(
            at: ScreenGeometry.cgPoint(fromDisplayLocal: point, display: display),
            in: windows
        )
    }

    /// 窗口在该显示器上的可见矩形（显示器局部坐标）；完全不在屏内时返回 nil。
    static func highlightRect(
        for window: WindowDescriptor,
        display: DisplayDescriptor
    ) -> CGRect? {
        let bounds = CGRect(origin: .zero, size: display.pointSize)
        let local = ScreenGeometry.displayLocalRect(fromCG: window.frame, display: display)
        let clipped = local.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return nil
        }
        return clipped
    }
}
