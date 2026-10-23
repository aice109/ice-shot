import AppKit
import CoreGraphics

/// 贴图窗口的内容视图。
///
/// 为什么不用 SwiftUI：
/// - 拖动走 AppKit 原生 `performDrag(with:)`，窗口跟随由窗口服务器负责，
///   不再由 SwiftUI 手势逐帧 `setFrameOrigin`——快速拖动时不会滞后、抖动或留残影；
/// - 图片用 layer 的 `contents` 显示，缩放交给 GPU 合成，不触发每帧 SwiftUI 重绘。
///
/// 交互与 SwiftUI 版保持一致：拖动内容 = 移动，靠近四边四角 = 等比缩放，
/// 双击复位，右键出菜单（菜单内容由 `PinWindowController` 提供）。
///
/// **光标提示依赖「面板能成为 key」+ `.cursorUpdate` 跟踪区**（实测结论）：
/// 非 key 的 `nonactivatingPanel` 在 App 未激活时，系统**不会派发任何鼠标跟踪事件**
/// （`mouseMoved` / `mouseEntered` / `cursorUpdate` 都不来），
/// `NSCursor.push()` 也不生效——这是 macOS 的已知行为。
/// 因此 `PinPanel.canBecomeKey` 改为 true（`.nonactivatingPanel` 仍保证不激活 App），
/// 并在这里用 `.cursorUpdate` 跟踪区处理光标；`mouseMoved` 作为第二条路径并存。
@MainActor
final class PinImageView: NSView {
    private unowned let controller: PinWindowController
    /// 一次拖动 / 缩放：按下瞬间决定模式，并记住当时的窗口 frame。
    private var dragBaseFrame: CGRect?
    private var dragEdge: PinGeometry.ResizeEdge?
    private var dragStartPoint: CGPoint = .zero
    /// 拖拽期间要「按住」的光标；为 nil 表示不在拖拽。
    private var dragCursor: PointerCursor?

    init(controller: PinWindowController, frame: CGRect) {
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = controller.image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(controller.name)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// 与 `PinGeometry` 的坐标约定一致（y 向下），边缘判定可以直接复用。
    override var isFlipped: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - 光标

    /// 整个视图一个 `.cursorUpdate` 跟踪区：系统按位置回调 `cursorUpdate(with:)`。
    ///
    /// - `.cursorUpdate`：光标形状的唯一权威来源（会在指针移动时反复回调）；
    /// - `.activeAlways`：面板失去 key、App 退到后台也要继续回调；
    /// - `.inVisibleRect`：热区跟着视图尺寸自动走，窗口缩放后不用手动重建；
    /// - `.mouseEnteredAndExited`：进场立刻给一次正确光标，离场还原。
    ///
    /// 同时保留 `.mouseMoved`，让 `mouseMoved` 也能兜住（部分系统版本上
    /// `cursorUpdate` 的触发时机更晚，两条路径都写不会打架——都调同一个 `apply`）。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .cursorUpdate,
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentCursor(at: point).apply()
    }


    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentCursor(at: point).apply()
    }

    /// 第二条路径：key 面板上 `mouseMoved` 也会派发，兜住 `cursorUpdate` 的时机差异。
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentCursor(at: point).apply()
    }

    override func mouseExited(with event: NSEvent) {
        // 拖拽中不改：拖出窗口再拖回来要还是缩放箭头。
        guard dragCursor == nil else { return }
        PointerCursor.arrow.apply()
    }

    /// 边缘 → 该方向的缩放箭头；内容区 → 抓手（整块可挪）。
    ///
    /// 拖拽中一律用按下时定下的光标，避免指针离开热区后中途跳回箭头。
    private func currentCursor(at point: CGPoint) -> PointerCursor {
        if let dragCursor {
            return dragCursor
        }
        guard let edge = PinGeometry.edge(at: point, in: bounds.size) else {
            return .move
        }
        return .resizing(edge.axis)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2 {
            controller.resetPresentation()
            return
        }

        let edge = PinGeometry.edge(at: point, in: bounds.size)
        if let edge {
            // 缩放：自己跟踪，保持对面那条边固定。窗口缩放本来就是应用侧行为。
            dragBaseFrame = controller.baseFrame
            dragEdge = edge
            dragStartPoint = point
            // 按住期间固定成该方向的缩放箭头，中途拖出窗口也不会跳回箭头。
            dragCursor = .resizing(edge.axis)
            dragCursor?.apply()
            return
        }

        // 移动：交给系统拖窗口，性能与手感都是原生的。
        dragCursor = .closedHand
        dragCursor?.apply()
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let baseFrame = dragBaseFrame, let dragEdge else {
            return
        }
        // 系统可能在拖拽中派发 cursorUpdate，这里再按一次保证不被覆盖。
        dragCursor?.apply()
        let point = convert(event.locationInWindow, from: nil)
        controller.resize(
            from: baseFrame,
            edge: dragEdge,
            translation: CGSize(
                width: point.x - dragStartPoint.x,
                height: point.y - dragStartPoint.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragBaseFrame = nil
        dragEdge = nil
        dragCursor = nil
        // 松手后按松手位置恢复（可能已经不在同一个热区上了）。
        currentCursor(at: convert(event.locationInWindow, from: nil)).apply()
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(controller.makeContextMenu(), with: event, for: self)
    }
}
