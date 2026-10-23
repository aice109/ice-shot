import AppKit

/// 长截图采集期间盖在选区上的一圈边框。
///
/// 选区浮层在松手后就关闭了，用户需要知道「正在抓哪一块」；这层边框是
/// **点击穿透、非激活**的，不影响用户在目标窗口里滚动。抓取时会按 App 排除
/// IceShot 自己的窗口，所以边框不会进长图。
@MainActor
final class ScrollCaptureFrameController {
    private var panel: NSPanel?

    func present(screenRect: CGRect) {
        dismiss()
        guard screenRect.width >= 1, screenRect.height >= 1 else { return }

        let panel = NSPanel(
            contentRect: screenRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentView = ScrollCaptureFrameView(frame: CGRect(origin: .zero, size: screenRect.size))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private final class ScrollCaptureFrameView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let border = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(rect: border)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        // 四角加粗，帮助在浅色内容上也看得清。
        let corner: CGFloat = 16
        let corners: [NSRect] = [
            NSRect(x: border.minX, y: border.minY, width: corner, height: 3),
            NSRect(x: border.minX, y: border.minY, width: 3, height: corner),
            NSRect(x: border.maxX - corner, y: border.minY, width: corner, height: 3),
            NSRect(x: border.maxX - 3, y: border.minY, width: 3, height: corner),
            NSRect(x: border.minX, y: border.maxY - 3, width: corner, height: 3),
            NSRect(x: border.minX, y: border.maxY - corner, width: 3, height: corner),
            NSRect(x: border.maxX - corner, y: border.maxY - 3, width: corner, height: 3),
            NSRect(x: border.maxX - 3, y: border.maxY - corner, width: 3, height: corner),
        ]
        for rect in corners {
            NSBezierPath(rect: rect).fill()
        }
    }
}
