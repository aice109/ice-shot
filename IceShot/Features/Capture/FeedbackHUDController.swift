import AppKit
import SwiftUI

/// 纯 AppKit 的反馈胶囊：一轮圆角背景 + 一行文字。
///
/// 用 AppKit 而不是 SwiftUI，是为了在任何调用栈里都能安全创建——
/// 这个面板经常出现在「SwiftUI 视图正在拆除」的栈上（见 `FeedbackHUDController.show`）。
private final class FeedbackBadgeView: NSView {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        // 与 `glassSurface(.clear)` 观感一致：半透明深色底 + 细描边。
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .callout),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = message as NSString
        let textSize = text.size(withAttributes: attributes)
        let origin = CGPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        )
        text.draw(at: origin, withAttributes: attributes)
    }

    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .callout),
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width) + 28, height: ceil(size.height) + 18)
    }
}

/// 复制 / 保存成功后的轻量反馈，不申请通知权限。
@MainActor
final class FeedbackHUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// 在鼠标所在屏幕底部显示一条短提示，1.4 秒后自动消失。
    func show(_ message: String) {
        dismiss()

        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.screens.first

        guard let screen else { return }

        // 宽度按文字实测，避免英文提示被截断（之前固定 240 pt）。
        let badge = FeedbackBadgeView(message: message)
        let size = badge.intrinsicContentSize
        let origin = CGPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 72
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = preferredLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // **刻意不用 `NSHostingView`**。
        //
        // 反馈面板经常是在「截取浮层正在拆除」的同步栈里被创建的（见 `pinResult`）。
        // 那一刻再嵌一个 SwiftUI 宿主，等于在 SwiftUI 自己的拆除过程中重入它的
        // 状态容器与图更新，实测会导致点「贴图」后主线程卡死。
        // 这里改用纯 AppKit 画一个胶囊 + 文字：没有 SwiftUI 参与，也就不存在重入。
        panel.contentView = badge
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.4))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// 面板层级：普通情况下 `.statusBar`，但截取浮层用的是 `.screenSaver`（更高），
    /// 取字 / 就地编辑期间的提示会被浮层遮住——那时抬到浮层上方一层。
    private var preferredLevel: NSWindow.Level {
        let overlayLevel = NSWindow.Level.screenSaver
        let overlayOnScreen = NSApp.windows.contains { window in
            window.isVisible && window.level == overlayLevel
        }
        return overlayOnScreen
            ? NSWindow.Level(rawValue: overlayLevel.rawValue + 1)
            : .statusBar
    }

    /// 立即关闭并释放；重复调用是安全的。
    func dismiss() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel?.close()
        panel?.contentView = nil
        panel = nil
    }
}
