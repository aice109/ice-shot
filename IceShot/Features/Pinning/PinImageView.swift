import AppKit
import CoreGraphics

/// 贴图窗口的内容视图。
///
/// 交互契约（用户明确指定的场景，改动前先回来读这一段）：
/// 1. **只有四个角**能缩放，按比例（等比）缩放，缩放过程实时跟手；
/// 2. 指针在图外 = 系统正常箭头（窗口收不到事件，自然不会覆盖光标）；
/// 3. 指针在图内（四周边 + 内部）= 抓手（`openHand`）；
/// 4. 按下拖动 = 抓紧（`closedHand`），松开还原抓手；
/// 5. 唯一例外：指针落在关闭按钮上 = 正常箭头，按下即关闭。
///
/// 为什么不用 SwiftUI：
/// - 拖动走 AppKit 原生 `performDrag(with:)`，窗口位移由窗口服务器负责，
///   不逐帧 `setFrameOrigin`，快速拖动不会滞后或留残影；
/// - 图片用 layer 的 `contents` 显示，缩放只改**图层几何**，由 GPU 合成。
///
/// **为什么缩放不改窗口 frame（跟手性的关键）**：
/// 贴图就是一个显示图像的窗口，缩放的视觉本质是「图变大变小」。
/// 如果每帧 `setFrame`，窗口服务器要做一次窗口尺寸变更 + 重新分配绘制表面，
/// 这条路径几十毫秒起，指针每动一下只来得及提交一帧，看起来就是「一卡一卡追」。
/// 因此拖拽期间只改 `contentLayer` 的 bounds（CoreAnimation 自己插值合成），
/// 窗口 frame 留到松手时一次性提交。
///
/// **光标提示依赖「面板能成为 key」+ `.cursorUpdate` 跟踪区**（实测结论）：
/// 非 key 的 `nonactivatingPanel` 在 App 未激活时，系统**不会派发任何鼠标跟踪事件**
/// （`mouseMoved` / `mouseEntered` / `cursorUpdate` 都不来），
/// `NSCursor.set()` 也不生效——这是 macOS 的已知行为。
/// 因此 `PinPanel.canBecomeKey` 改为 true（`.nonactivatingPanel` 仍保证不激活 App），
/// 并在这里用 `.cursorUpdate` 跟踪区处理光标；`mouseMoved` 作为第二条路径并存。
@MainActor
final class PinImageView: NSView {
    private unowned let controller: PinWindowController

    // MARK: - 拖拽状态

    /// 按下瞬间的窗口 frame（屏幕坐标）。缩放时用它换算固定的对角点。
    private var dragBaseFrame: CGRect?
    /// 按下瞬间命中的角（`.move` 表示整块拖动）。
    private var dragZone: PinGeometry.HitZone?
    /// 按下瞬间指针在**屏幕坐标**里的位置（缩放换算的基准）。
    /// 按下瞬间指针的**屏幕坐标**。
    ///
    /// 必须是屏幕坐标：缩放期间窗口的尺寸和原点都在变，
    /// `locationInWindow` 的参照系每帧都不同，拿它当绝对位置会累积误差
    /// （「缩得越厉害角越偏」就是这么来的）。`NSEvent.mouseLocation` 不随窗口变化。
    private var dragPressScreenPoint: CGPoint = .zero
    /// 缩放过程中的等比系数（1 = 按下时的尺寸），仅用于跳过重复的 frame 计算。
    private var dragScale: CGFloat = 1

    /// 指针是否在贴图上：关闭按钮只在悬停时出现，不遮挡图片内容。
    private var isHovering = false
    /// 关闭按钮的图层（懒创建，只在需要时加进视图）。
    private var closeButtonLayer: CALayer?
    /// 承载图片的图层。
    ///
    /// 必须是独立子层而不是视图自己的 backing layer：视图的 backing layer 尺寸
    /// 被 AppKit 钉死在 bounds 上，缩放时去改它会被布局立刻纠正回来。
    /// 独立子层可以自由变大变小（超出窗口的部分由 `masksToBounds` 裁掉，
    /// 松手提交窗口 frame 后正好铺满），缩放期间完全不需要碰窗口。
    private var contentLayer: CALayer?

    init(controller: PinWindowController, frame: CGRect) {
        self.controller = controller
        super.init(frame: frame)
        // `wantsLayer` 只是「打算用图层」；`layer` 属性**要到视图有了 backing layer
        // 才非 nil**。在 init 里直接读它会在窗口显示前触发按需创建，
        // 而这条创建路径若发生在 SwiftUI 按钮 action 的同步栈里就会卡住（实测）。
        // 真正的 contents 赋值放在 `viewDidMoveToWindow`，那时图层一定就绪。
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(controller.name)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// 与 `PinGeometry` 的坐标约定一致（y 向下），命中判定可以直接复用。
    override var isFlipped: Bool { true }

    /// 图层内容在这里配置：此时视图已经挂在窗口上，`layer` 必然可用。
    private func configureLayerIfNeeded() {
        guard let host = layer, contentLayer == nil else { return }
        host.masksToBounds = true

        let image = CALayer()
        image.contents = controller.image
        image.contentsGravity = .resize
        // 缩放用线性采样即可：贴图是位图，放大不需要平滑到发糊。
        image.magnificationFilter = .linear
        image.minificationFilter = .linear
        host.addSublayer(image)
        contentLayer = image

        applyLayerGeometry()
    }

    /// 把 `contentLayer` / 关闭按钮摆到当前 bounds 上（纯几何，不碰显隐）。
    ///
    /// 关掉隐式动画：缩放时每帧都会走到这里，若 CoreAnimation 在
    /// `bounds` / `position` 上插值，看到的就不是指针所在的那一帧，
    /// 而是上一帧到当前帧之间的过渡值——这正是「拖影」。
    private func applyLayerGeometry() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let contentLayer {
            let frame = CGRect(origin: .zero, size: bounds.size)
            // 视图是 flipped、图层不是：用 bounds + anchorPoint(0,0) 让右上/左下都不镜像，
            // 这里整块铺满视图，直接按 size 给 bounds、把锚点放左上。
            contentLayer.anchorPoint = CGPoint(x: 0, y: 0)
            contentLayer.bounds = CGRect(origin: .zero, size: frame.size)
            contentLayer.position = .zero
            contentLayer.contentsScale = scale
        }
        if let closeButtonLayer {
            positionCloseButton(closeButtonLayer)
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyLayerGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayerGeometry()
    }

    override func layout() {
        super.layout()
        // 只做几何定位：这里**不能**调 `updateCloseButton()`——
        // 它写 `isHidden` 会再触发一次布局，形成无限递归。
        applyLayerGeometry()
    }

    // MARK: - 光标

    /// 整个视图一个 `.cursorUpdate` 跟踪区：系统按位置回调 `cursorUpdate(with:)`。
    ///
    /// - `.cursorUpdate`：光标形状的权威来源（指针移动时反复回调，保证实时）；
    /// - `.activeAlways`：App 失去激活也要继续回调；
    /// - `.inVisibleRect`：热区跟着视图尺寸自动走，缩放后不用手动重建；
    /// - `.mouseEnteredAndExited`：进场立刻给一次正确光标，离场还原箭头；
    /// - `.mouseMoved`：最后一道保险，部分系统版本上 `cursorUpdate` 时机更晚。
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

    // MARK: - 窗口 / 激活状态变化时的光标恢复

    /// 面板重新成为 key、或别的 App 被激活时重算光标。
    ///
    /// 典型场景：点其他 App 的窗口，再回到贴图。AppKit 在切换过程中会把光标
    /// 重置成箭头，而指针可能一动也不动、`cursorUpdate` 不会自动补一帧，
    /// 于是整张贴图的光标全变成箭头。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureLayerIfNeeded()

        // 先摘掉上一次的，避免 `viewDidMoveToWindow` 反复调用时重复注册。
        NotificationCenter.default.removeObserver(self)

        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowStateChanged),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            // 面板被别的窗口抢走 key 后，粘贴的指针可能还停在我们头上，
            // 退 key 也要补一次（否则光标停在旧形状）。
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowStateChanged),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }

        // App 级激活：点其他 App 再回来时，IceShot 作为菜单栏应用不一定
        // 会收到 `didBecomeActive`，所以两个都监听。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowStateChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(windowStateChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        refreshCursorForCurrentPointer()
    }

    /// 按**实时全局指针位置**重算并强制写入光标。
    ///
    /// 必须无条件写（不能走 `refreshCursor` 的去重分支）：
    /// App 切换、面板失 key 等过程中系统会把光标重置成箭头，
    /// 而我们的缓存 `lastAppliedCursor` 还停在旧值，去重会把恢复吞掉。
    private func refreshCursorForCurrentPointer() {
        guard window != nil else { return }
        let point = atCurrentMouseLocation()
        // 指针在贴图外就不插手，让系统 / 别的窗口决定光标。
        guard bounds.contains(point) else { return }
        setHovering(true)
        forceCursor(at: point)
    }

    override func cursorUpdate(with event: NSEvent) {
        refreshCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
        // 跟踪事件只在 key 窗口上派发。点过其他 App 再回来时面板可能已不是 key，
        // 先抢回 key（`.nonactivatingPanel` 不会激活 App、不抢键盘焦点），
        // 否则接下来的 cursorUpdate 全都不会来。
        controller.ensureKeyForPointerTracking()
        // 进场必须无条件写一次：光标是全局状态，进来之前可能是别的 App
        // 留下的任何形状，不能因为「和缓存相同」就跳过。
        forceCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// 第二条路径：key 面板上 `mouseMoved` 也会派发，兜住 `cursorUpdate` 的时机差异。
    /// 两条路径都调同一个 `refreshCursor`，不会打架。
    override func mouseMoved(with event: NSEvent) {
        setHovering(true)
        refreshCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// 指针离开贴图：恢复正常箭头。
    ///
    /// 这一步是必需的——贴图是个独立窗口，窗口外的区域属于别的 App，
    /// 没有这行的话光标会停在抓手 / 缩放箭头上一路走到别处去。
    override func mouseExited(with event: NSEvent) {
        // 拖拽中不改：拖出窗口再拖回来还要保持抓紧 / 缩放态。
        guard dragZone == nil else { return }
        setHovering(false)
        forceCursor(.arrow)
    }

    /// 按位置实时更新光标。拖拽中一律用按下时定下的那个，不随指针漂移而跳变。
    private func refreshCursor(at point: CGPoint) {
        let cursor = dragCursor(at: point)
        // 只在变化时写系统光标：`NSCursor.set()` 每次都触发一次光标更新，
        // 高频 `mouseMoved` 下无谓地重复设置会拖慢指针跟手性。
        guard cursor != lastAppliedCursor else { return }
        forceCursor(cursor)
    }

    /// 无条件写系统光标，并同步缓存（进场 / 离场 / 拖拽开始这类转折点用）。
    private func forceCursor(at point: CGPoint) {
        forceCursor(dragCursor(at: point))
    }

    private func forceCursor(_ cursor: PointerCursor) {
        lastAppliedCursor = cursor
        cursor.apply()
    }

    /// 当前该显示的光标。
    private func dragCursor(at point: CGPoint) -> PointerCursor {
        guard let dragZone else {
            return PinGeometry.hitZone(at: point, in: bounds.size).cursor
        }
        switch dragZone {
        case .move: return .closedHand
        case .resize(let edge): return .resize(edge.axis)
        // 按下就一定会关闭，光标保持箭头即可。
        case .closeButton: return .arrow
        }
    }

    /// 上一次写进系统的光标，用来跳过重复设置。
    private var lastAppliedCursor: PointerCursor = .arrow

    /// 悬停显隐关闭按钮。
    ///
    /// 贴图是为了「看一眼图上的东西」，常驻一个按钮会永远挡住右上角那块内容；
    /// 指针一进来才出现，离开就藏回去，和预览类应用的习惯一致。
    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        updateCloseButton()
    }

    /// 更新关闭按钮的显隐。
    ///
    /// 用 `CALayer` 而不是画在 `draw(_:)` 里：贴图的内容是 `layer.contents` 的图像，
    /// 重绘整块图只为了画一个小圆点是浪费；独立子图层改 `isHidden` 即可。
    ///
    /// **两条防递归措施，缺一不可**：
    /// 1. `layout()` 里只调 `applyLayerGeometry()`（纯几何，不碰 `isHidden`）；
    /// 2. 值与上次相同就跳过赋值——CoreAnimation 的属性写入会触发事务提交、
    ///    进而连锁触发布局，`layout()` 里若无条件再写一次就是**无限递归**，
    ///    主线程会被活活占死（点一下贴图就卡死正是这个）。
    private func updateCloseButton() {
        guard let layer = closeButtonLayer ?? makeCloseButtonLayer() else { return }
        closeButtonLayer = layer

        let shouldHide = !isHovering
        guard layer.isHidden != shouldHide else {
            applyLayerGeometry()
            return
        }
        // 关掉隐式动画：按钮是「出现 / 消失」，不该有 0.25 s 的淡入淡出，
        // 否则快速划过贴图时会看到一串拖影。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionCloseButton(layer)
        layer.isHidden = shouldHide
        CATransaction.commit()
    }

    /// 纯几何：只改 frame，不碰显隐，因此可以安全地在 `layout()` 里调用。
    private func positionCloseButton(_ layer: CALayer) {
        let diameter = PinGeometry.closeButtonDiameter
        let center = PinGeometry.closeButtonCenter(in: bounds.size)

        // 父视图是 `isFlipped`（左上原点），但一个**非 flipped** 的 `CALayer`
        // 里 y 轴向上：直接写 `frame` 会让按钮上下镜像，跑到左下角去。
        // 用 `position`（锚点 0.5/0.5 时就是中心点）+ 显式 `bounds` 最稳。
        let position = CGPoint(x: center.x, y: center.y)
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        guard layer.position != position || layer.bounds != bounds else { return }

        // 布局期间不允许隐式动画，否则首次定位会看到按钮从原点飞过来。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = bounds
        layer.position = position
        CATransaction.commit()
    }

    private func makeCloseButtonLayer() -> CALayer? {
        // 没有 backing layer 就不装按钮：宁可少个按钮，也不要在 nil 上写属性
        // 触发隐式动画 / 异常。
        guard let hostLayer = layer else { return nil }
        let diameter = PinGeometry.closeButtonDiameter
        let layer = CALayer()
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer.zPosition = 1

        // 叉号用一条 CAShapeLayer 描两条线，避免依赖图片资源。
        let shape = CAShapeLayer()
        let inset: CGFloat = 5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: diameter - inset, y: diameter - inset))
        path.move(to: CGPoint(x: diameter - inset, y: inset))
        path.addLine(to: CGPoint(x: inset, y: diameter - inset))
        shape.path = path
        shape.strokeColor = NSColor.white.cgColor
        shape.lineWidth = 1.5
        shape.lineCap = .round
        shape.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        shape.position = CGPoint(x: diameter / 2, y: diameter / 2)
        layer.addSublayer(shape)

        hostLayer.addSublayer(layer)
        return layer
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let zone = PinGeometry.hitZone(at: point, in: bounds.size)

        switch zone {
        case .closeButton:
            // 关闭优先于一切：按钮与右上角缩放热区重叠，放在最前面判定，
            // 避免想关却把贴图拉变形了。
            controller.close()
            return

        case .resize:
            if event.clickCount == 2 {
                controller.resetPresentation()
                return
            }
            dragBaseFrame = controller.baseFrame
            dragZone = zone
            dragPressScreenPoint = NSEvent.mouseLocation
            dragScale = 1
            controller.beginResize()
            refreshCursor(at: point)

        case .move:
            if event.clickCount == 2 {
                controller.resetPresentation()
                return
            }
            dragZone = zone
            // 抓紧：按下立刻变 `closedHand`，并压栈，防止 `cursorUpdate` 覆盖回去。
            forceCursor(.closedHand)
            controller.setDraggingCursor(.closedHand)
            // 移动：交给系统拖窗口，性能与手感都是原生的。
            // 注意：`performDrag` 会一直阻塞到松手，期间的 `mouseDragged`
            // 不会派发到这个视图——这是系统拖窗口的机制。
            window?.performDrag(with: event)
            // `performDrag` 返回 = 已经松手，这里直接收尾（`mouseUp` 可能随后再来，
            // 重复调用 `endDrag` 无副作用）。
            // 注意不能用 `event.locationInWindow`：那是按下时的坐标，
            // 而窗口已经跟着指针挪走了。松手位置要按当前全局指针重新算。
            endDrag(at: atCurrentMouseLocation())
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let baseFrame = dragBaseFrame,
              case .resize(let edge) = dragZone else { return }

        // 用**屏幕绝对坐标**算，与窗口当前尺寸、当前位置无关。
        // 旧实现用 `event.locationInWindow`：缩放时窗口自己在变大小、原点也在跑，
        // 那个参照系每帧都不同，误差会随缩放幅度累积（「缩得越厉害角越偏」）。
        let targetHeight = PinGeometry.targetHeight(
            pointer: NSEvent.mouseLocation,
            baseFrame: baseFrame,
            pressPoint: dragPressScreenPoint,
            edge: edge,
            imageAspect: controller.imageAspect
        )
        let scale = baseFrame.height > 0 ? targetHeight / baseFrame.height : 1
        guard scale != dragScale else { return }
        dragScale = scale
        // 按比例把窗口整个缩放：`resize(toHeight:anchor:)` 内部会保持图片比例、
        // 固定对角点，并在 frame 未变时跳过 `setFrame`。
        controller.resize(toHeight: targetHeight, anchor: edge)
    }

    override func mouseUp(with event: NSEvent) {
        // 缩放走的是自己跟踪的 `mouseDragged`，`mouseUp` 位置是可靠的；
        // 但统一用当前全局指针位置，两条路径行为一致。
        endDrag(at: atCurrentMouseLocation())
    }

    /// 当前指针在本视图坐标里的位置。
    ///
    /// 统一入口：`performDrag` 之后窗口已经挪位，旧事件坐标不再有效，
    /// 只有实时全局指针位置（`NSEvent.mouseLocation`）是对的。
    private func atCurrentMouseLocation() -> CGPoint {
        guard let window else { return .zero }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    /// 收尾拖拽：清状态、出栈光标、按当前指针位置重置光标。
    ///
    /// 幂等：``performDrag`` 返回后和 `mouseUp` 都会调，重复调用只是空转。
    private func endDrag(at point: CGPoint) {
        let finishedZone = dragZone
        guard finishedZone != nil else { return }
        dragZone = nil
        dragBaseFrame = nil
        dragScale = 1

        if case .resize = finishedZone {
            controller.endResize()
            refreshCursor(at: point)
        } else {
            controller.releaseDraggingCursor()
            // 出栈后把光标强制刷回「抓手 / 箭头」，避免停在抓紧态。
            forceCursor(at: point)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(controller.makeContextMenu(), with: event, for: self)
    }
}
