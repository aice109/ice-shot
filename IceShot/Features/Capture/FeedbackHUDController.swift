import AppKit
import SwiftUI

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

        let size = NSSize(width: 240, height: 44)
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
        panel.contentView = NSHostingView(
            rootView: Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassSurface(contrast: .elevated, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
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
