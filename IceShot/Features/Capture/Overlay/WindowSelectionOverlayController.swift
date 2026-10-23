import AppKit
import SwiftUI

/// 展示 / 关闭窗口选择浮层的抽象，便于截图流程与具体 AppKit 窗口解耦。
@MainActor
protocol WindowSelectionOverlayPresenting {
    func present(
        frames: [DisplayFrame],
        windows: [WindowDescriptor],
        onPick: @escaping (WindowDescriptor) -> Void,
        onCancel: @escaping () -> Void
    )
    func dismiss()
}

/// 多显示器窗口选择浮层控制器。
///
/// 为每块显示器创建一个 `.screenSaver` 层级的无边框面板，共享同一份
/// `WindowHoverState` 与窗口目录；面板只覆盖冻结帧，不改变真实屏幕内容。
@MainActor
final class WindowSelectionOverlayController: WindowSelectionOverlayPresenting {
    private var panels: [CaptureOverlayPanel] = []
    private var state: WindowHoverState?
    private var windows: [WindowDescriptor] = []
    private var keyMonitor: Any?
    private var onPick: ((WindowDescriptor) -> Void)?
    private var onCancel: (() -> Void)?
    private var isPicking = false

    func present(
        frames: [DisplayFrame],
        windows: [WindowDescriptor],
        onPick: @escaping (WindowDescriptor) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()
        self.onPick = onPick
        self.onCancel = onCancel
        self.windows = windows
        let state = WindowHoverState()
        self.state = state

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // Esc：取消整次选择
                self.cancel()
                return nil
            case 36: // Return：确认当前悬停窗口
                if self.pickHoveredWindow() {
                    return nil
                }
                return event
            default:
                return event
            }
        }

        for frame in frames {
            let view = WindowSelectionOverlayView(
                frame: frame,
                windows: windows,
                state: state,
                onPick: { [weak self] window in
                    self?.pick(window)
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )

            let panel = CaptureOverlayPanel(
                contentRect: frame.display.appKitFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle,
                .transient,
            ]
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.animationBehavior = .none
            panel.becomesKeyOnlyIfNeeded = false
            panel.isReleasedWhenClosed = false
            panel.contentView = FirstMouseHostingView(rootView: AnyView(view))
            panel.setFrame(frame.display.appKitFrame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        let cursor = NSEvent.mouseLocation
        if let keyPanel = panels.first(where: { $0.frame.contains(cursor) }) {
            keyPanel.makeKey()
        } else {
            panels.first?.makeKey()
        }
    }

    func dismiss() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
            panel.contentView = nil
        }
        panels.removeAll()
        state?.clearAll()
        state = nil
        windows.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        onPick = nil
        onCancel = nil
        isPicking = false
    }

    private func pick(_ window: WindowDescriptor) {
        guard !isPicking else { return }
        isPicking = true
        let callback = onPick
        dismiss()
        // dismiss() 会复位 isPicking；保持到下一次 present，避免重复回调。
        isPicking = true
        callback?(window)
    }

    private func pickHoveredWindow() -> Bool {
        guard let id = state?.windowID,
              let window = windows.first(where: { $0.id == id }) else {
            return false
        }
        pick(window)
        return true
    }

    private func cancel() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}
