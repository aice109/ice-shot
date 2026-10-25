import CoreGraphics

/// 屏幕坐标 ↔ 浮层视图坐标的**唯一**换算。
///
/// 为什么单独抽出来：这套换算在三个地方各写了一遍
/// （浮层首帧播种、`SelectionOverlayView.initialCursorPosition`、面板鼠标监视器），
/// 而它们曾经**不一致**——监视器用 `contentView.bounds.height` 做 y 翻转，另外两处用
/// `appKitFrame.maxY - mouse.y`。一旦 `NSHostingView` 的高度与面板 frame 不同
/// （多屏 / 非主屏 / 带标题栏），两套坐标就差一截，表现是「指针明明在选区里，
/// 顶部一点却判成了选区外」——正是真机上遇到的「顶部一点就变成禁用」。
///
/// 现在只留一个公式，三处都调它，纯函数、可直接单测。
///
/// 坐标约定：
/// - 输入 `mouse` 是 AppKit 全局屏幕坐标（主屏左下角为原点，y 向上）；
/// - 输出是浮层视图坐标（**左上原点，y 向下**，单位 points），与 `selection` 同一坐标系。
enum OverlayCoordinates {
    /// 全局屏幕点 → 某块显示器上的浮层视图坐标。
    ///
    /// - Parameters:
    ///   - mouse: `NSEvent.mouseLocation` 这类 AppKit 全局坐标。
    ///   - displayFrame: 该显示器的 `appKitFrame`。
    /// - Returns: 视图坐标；指针不在这块显示器上时返回 `nil`。
    static func viewPoint(fromScreen mouse: CGPoint, displayFrame: CGRect) -> CGPoint? {
        guard containsInclusive(displayFrame, mouse) else { return nil }
        return CGPoint(
            x: mouse.x - displayFrame.minX,
            // AppKit 的 y 向上、视图坐标 y 向下：距离上边缘 = maxY - mouse.y。
            y: displayFrame.maxY - mouse.y
        )
    }

    /// 闭区间包含判断。
    ///
    /// 不能直接用 `CGRect.contains`：它是**半开**的（含 minX/minY、不含 maxX/maxY），
    /// 于是屏幕最上一行 / 最右一列永远判成「不在屏幕上」——真机表现就是
    /// 「贴到顶部一点，光标就变成禁用」。指针落在边界上属于这块屏幕。
    static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// 不经屏幕坐标：已知「指针距窗口左边 / 上边多少」时直接得到视图坐标。
    ///
    /// `NSEvent.locationInWindow` 是窗口左下原点，所以要按窗口高度翻转。
    /// 这里用窗口（面板）自己的 `height`，与 `appKitFrame.size.height` 同源，
    /// 不能用某个子视图的 bounds——那可能与窗口尺寸不一致。
    static func viewPoint(fromWindow point: CGPoint, windowHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: windowHeight - point.y)
    }
}
