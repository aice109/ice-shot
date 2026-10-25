import AppKit

/// 一张贴图 = 一个置顶的无边框面板。
///
/// 设计取舍：
/// - 用 `NSPanel` 而不是 `NSWindow`：面板不参与激活策略判定，贴图出现不会让 Dock 图标跳出来；
/// - **面板可以成为 key，但不激活 App、不抢键盘焦点**（`.nonactivatingPanel`）。
///   光标提示必须这样：非 key 窗口收不到任何跟踪事件（实测）；
/// - 所有交互都在 `PinImageView` 里用 AppKit 完成（原生窗口拖动 + 自跟踪缩放），
///   内容不经过 SwiftUI，快速拖动不滞后、不残影；
/// - 关闭与「恢复交互」保留在菜单栏，穿透状态下也不会出现关不掉的窗口。
@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate, Identifiable {
    /// 右键菜单里的透明度档位。
    static let opacityLevels: [Double] = [1, 0.8, 0.6, 0.4]

    let id = UUID()
    let name: String
    let image: CGImage
    private(set) var isClickThrough = false
    private(set) var opacity: Double = 1
    private var dragAnchorFrame: CGRect?
    /// 拖拽中的光标栈（保证 push / pop 成对）。
    private let draggingCursor = PointerCursorStack()
    /// 窗口关闭时回调（由 `PinBoard` 清理注册表）。
    var onClose: (() -> Void)?

    init(image: CGImage, name: String, screenFrame: CGRect, scale: CGFloat) {
        self.image = image
        self.name = name

        let size = PinGeometry.initialSize(
            imageSize: CGSize(width: image.width, height: image.height),
            scale: scale,
            screenFrame: screenFrame
        )
        let origin = PinGeometry.origin(
            topLeft: nil,
            size: size,
            visibleFrame: screenFrame
        )
        let panel = PinPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        // `acceptsMouseMovedEvents` 只在窗口成为 key 时才有效。
        // 点过其他 App 再回到贴图时，面板可能已经不是 key 了，
        // 所以 `PinImageView.mouseEntered` 里会主动 `makeKey()` 抢回来。
        panel.acceptsMouseMovedEvents = true
        panel.contentMinSize = NSSize(
            width: PinGeometry.minimumSize,
            height: PinGeometry.minimumSize
        )
        panel.animationBehavior = .none
        panel.setAccessibilityLabel(name)

        super.init(window: panel)

        panel.delegate = self
        let content = PinImageView(controller: self, frame: CGRect(origin: .zero, size: size))
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        panel.setFrame(panel.frame, display: false)
        // 贴图面板必须**先登记为窗口，再显示**：`show(at:)` 里 `makeKeyAndOrderFront`
        // 之前若窗口还挂着未完成的首帧布局，AppKit 会在窗口服务器等待中重入布局。
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }

    // MARK: - key 状态与光标恢复

    /// 指针进入贴图时让它重新成为 key。
    ///
    /// 为什么必需：`cursorUpdate` / `mouseMoved` 这些跟踪事件**只在 key 窗口上派发**。
    /// 用户点一下别的 App 再回到贴图时，面板已经不是 key 了，于是光标永远停在
    /// 「离开时那个箭头」上——明明悬停在四角却是箭头，四边也不变成抓手。
    ///
    /// `makeKey()` 在 `.nonactivatingPanel` 下只把本窗口设为 key，
    /// **不会激活 App、不会切走用户当前的应用**，也不会抢键盘焦点。
    func ensureKeyForPointerTracking() {
        guard let panel = window else { return }
        guard !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    // MARK: - 展示

    /// 贴在屏幕上：`topLeft` 为空时居中在当前鼠标所在屏幕。
    func show(at topLeft: CGPoint?) {
        guard let panel = window else { return }
        let screen = screenContaining(topLeft) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PinGeometry.origin(
            topLeft: topLeft,
            size: panel.frame.size,
            visibleFrame: visibleFrame
        )
        panel.setFrameOrigin(origin)
        // 先成为 key 再显示：光标提示（`cursorUpdate`）只在 key 窗口上生效。
        // `.nonactivatingPanel` 保证这不会激活 App、也不会切走用户当前窗口。
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - 交互

    /// 拖动开始时的窗口 frame；后续位移都基于它换算，避免累计误差。
    var baseFrame: CGRect {
        window?.frame ?? .zero
    }

    var imageAspect: CGFloat {
        image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 1
    }

    /// 缩放中直接按「目标高度」设 frame。
    ///
    /// 不含任何「基准 frame + 位移」的中间量：每次 `mouseDragged` 都把指针的
    /// 绝对位置折算成目标高度传进来，所以指针离开贴图、事件合帧、
    /// 跨屏换 scale 都不会产生累计偏差。
    /// 固定边取自缩放开始时记住的 `dragAnchorFrame`——不是每帧的 `window.frame`，
    /// 因为窗口自己的 origin 在缩放中一直在变。
    func resize(toHeight height: CGFloat, anchor: PinGeometry.ResizeEdge) {
        guard let panel = window else { return }
        let base = dragAnchorFrame ?? panel.frame
        let frame = PinGeometry.frameSizedToHeight(
            baseFrame: base,
            height: height,
            imageAspect: imageAspect,
            anchor: anchor
        )
        // frame 没变就不要打扰窗口服务器：拖拽高频事件里大多数帧是重复的。
        guard frame != panel.frame else { return }
        // `display: false`：内容由图层自己铺满，不需要每次同步重绘。
        panel.setFrame(frame, display: false)
    }

    /// 记录缩放开始时的 frame。
    func beginResize() {
        dragAnchorFrame = window?.frame
    }

    func endResize() {
        dragAnchorFrame = nil
    }

    // MARK: - 拖拽光标

    /// 按下时把「抓紧」压栈，保证拖拽全程不被 `cursorUpdate` 覆盖。
    func setDraggingCursor(_ cursor: PointerCursor) {
        draggingCursor.push(cursor)
    }

    /// 松手时出栈（成对，重复调用无副作用）。
    func releaseDraggingCursor() {
        draggingCursor.pop()
    }

    /// 双击恢复 100% 透明度与原始显示尺寸。
    func resetPresentation() {
        setOpacity(1)
        guard let panel = window else { return }
        let screen = panel.screen ?? NSScreen.main
        let size = PinGeometry.initialSize(
            imageSize: CGSize(width: image.width, height: image.height),
            scale: screen?.backingScaleFactor ?? 2,
            screenFrame: screen?.visibleFrame ?? panel.frame
        )
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true)
    }

    func setOpacity(_ value: Double) {
        opacity = min(max(value, 0.2), 1)
        window?.alphaValue = CGFloat(opacity)
    }

    func setClickThrough(_ enabled: Bool) {
        isClickThrough = enabled
        window?.ignoresMouseEvents = enabled
    }

    func copyToPasteboard() {
        try? ClipboardWriter().copy(image)
    }

    // MARK: - 右键菜单

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(String(localized: "复制"), action: #selector(copyAction)))
        menu.addItem(menuItem(String(localized: "恢复原始大小与不透明度"), action: #selector(resetAction)))
        menu.addItem(.separator())

        let opacityItem = NSMenuItem(title: String(localized: "不透明度"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for level in Self.opacityLevels {
            let item = menuItem("\(Int(level * 100))%", action: #selector(setOpacityAction(_:)))
            item.representedObject = level
            item.state = abs(opacity - level) < 0.001 ? .on : .off
            submenu.addItem(item)
        }
        opacityItem.submenu = submenu
        menu.addItem(opacityItem)

        let throughItem = menuItem(String(localized: "点击穿透"), action: #selector(toggleClickThroughAction))
        throughItem.state = isClickThrough ? .on : .off
        menu.addItem(throughItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "关闭贴图"), action: #selector(closeAction)))
        return menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyAction() {
        copyToPasteboard()
    }

    @objc private func resetAction() {
        resetPresentation()
    }

    @objc private func setOpacityAction(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Double else { return }
        setOpacity(level)
    }

    @objc private func toggleClickThroughAction() {
        setClickThrough(!isClickThrough)
    }

    @objc private func closeAction() {
        close()
    }

    private func screenContaining(_ point: CGPoint?) -> NSScreen? {
        guard let point else {
            return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
        }
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}

/// 无边框贴图面板：**可以成为 key**，但不激活 App、不抢焦点。
///
/// `canBecomeKey = true` 是光标提示的前提（实测）：
/// 非 key 的 `nonactivatingPanel` 在 App 未激活时，系统**不会派发任何鼠标跟踪事件**
/// （`mouseMoved` / `cursorUpdate` 都不来），`NSCursor.push()` 也无效——
/// 这是 macOS 已知行为（见 PitNikola/NonActivatingPanelIssue）。
/// 让面板能成为 key 后 `cursorUpdate(with:)` 正常回调，光标就能跟着热区变。
///
/// 不会因此抢走用户当前 App 的键盘焦点：`.nonactivatingPanel` 保证了
/// 「成为 key 但不激活所属 App」，这正是 Spotlight / 1Password 浮动面板的做法。
/// `canBecomeMain` 仍为 false——贴图不应该被当成主窗口。
/// 仍然不接收键盘输入：贴图没有任何文本输入需求。
private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
