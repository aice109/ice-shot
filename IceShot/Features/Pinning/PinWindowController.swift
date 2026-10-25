import AppKit

/// 一张贴图 = 一个置顶的无边框面板。
///
/// 设计取舍：
/// - 用 `NSPanel` 而不是 `NSWindow`：面板不参与激活策略判定，贴图出现不会让 Dock 图标跳出来；
/// - 面板不抢键盘焦点（`canBecomeKey = false`），所有交互都在 `PinImageView` 里用 AppKit 完成
///   （原生窗口拖动 + 原生视图缩放），内容不经过 SwiftUI，快速拖动不会滞后或残影；
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
        panel.becomesKeyOnlyIfNeeded = true
        // 注：`acceptsMouseMovedEvents` 只在窗口成为 key 时才有效，贴图面板常驻非 key，
        // 所以光标提示**不能**依赖 `mouseMoved`——改用 `NSTrackingArea` 的
        // `.cursorUpdate`（由窗口服务器驱动，不需要激活或 key 状态），见 `PinImageView`。
        // 保留这一项是为了在用户点进来（成为 key）时事件也完整。
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
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

    /// 拖边 / 拖角缩放：保持图片比例，固定对面那条边，最小 40 pt。
    func resize(
        from baseFrame: CGRect,
        edge: PinGeometry.ResizeEdge,
        translation: CGSize
    ) {
        guard let panel = window else { return }
        let frame = PinGeometry.resizedFrame(
            baseFrame: baseFrame,
            edge: edge,
            translation: translation,
            imageAspect: imageAspect
        )
        panel.setFrame(frame, display: true)
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
