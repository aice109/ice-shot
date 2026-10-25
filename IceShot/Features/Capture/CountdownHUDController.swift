import AppKit
import Observation
import SwiftUI

/// 延时截图倒计时的抽象；截图流程只关心「继续 / 取消」。
@MainActor
protocol CountdownPresenting {
    /// 返回 true 表示倒计时结束、可以继续截图；false 表示用户取消。
    func run(seconds: Int) async -> Bool
    func dismiss()
}

/// 倒计时 HUD 的可观察状态，供 SwiftUI 视图实时刷新剩余秒数。
@MainActor
@Observable
final class CountdownState {
    var remaining: Int
    let onCancel: () -> Void

    init(remaining: Int, onCancel: @escaping () -> Void) {
        self.remaining = remaining
        self.onCancel = onCancel
    }
}

/// 倒计时浮层控制器。
///
/// 浮层用 `.screenSaver` 层级，确保倒计时期间用户切换 App 也能看到；
/// 结束前先关闭 HUD 再等一帧，避免把倒计时数字截进最终图像。
@MainActor
final class CountdownHUDController: CountdownPresenting {
    private var panel: CaptureOverlayPanel?
    private var state: CountdownState?
    private var keyMonitor: Any?
    private var isCancelled = false

    func run(seconds: Int) async -> Bool {
        dismiss()
        guard seconds > 0 else {
            return true
        }

        isCancelled = false
        let state = CountdownState(remaining: seconds) { [weak self] in
            self?.cancel()
        }
        self.state = state
        showPanel(state: state)

        let end = Date().addingTimeInterval(TimeInterval(seconds))
        do {
            while Date() < end {
                if isCancelled {
                    dismiss()
                    return false
                }
                let remaining = max(1, Int(ceil(end.timeIntervalSinceNow)))
                if state.remaining != remaining {
                    state.remaining = remaining
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            if isCancelled {
                dismiss()
                return false
            }

            // 先关闭 HUD，再等一帧，避免把倒计时截进静态帧。
            dismiss()
            try await Task.sleep(for: .milliseconds(50))
            return !isCancelled
        } catch {
            dismiss()
            return false
        }
    }

    func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.close()
        panel?.contentView = nil
        panel = nil
        state = nil
    }

    private func showPanel(state: CountdownState) {
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.screens.first
        guard let screen else { return }

        let size = NSSize(width: 220, height: 150)
        let origin = CGPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )

        let panel = CaptureOverlayPanel(
            contentRect: CGRect(origin: origin, size: size),
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
            .transient,
        ]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentView = FirstMouseHostingView(
            rootView: AnyView(CountdownHUDView(state: state))
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else {
                return event
            }
            self?.cancel()
            return nil
        }
    }

    private func cancel() {
        isCancelled = true
        dismiss()
    }
}

private struct CountdownHUDView: View {
    let state: CountdownState

    var body: some View {
        VStack(spacing: 8) {
            Text("\(state.remaining)")
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("\(state.remaining) 秒")

            Text("秒后截图")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Button("取消") {
                state.onCancel()
            }
            .glassControlStyle()
            .help("取消延时截图（Esc）")
        }
        .padding(18)
        // 高度固定（居中数字的位置要稳），宽度给区间：
        // 中文「秒后截图」一行放得下 220pt，英文 "seconds until capture" 会超出，
        // 允许它撑到 300pt，而不是把字缩成看不清或直接截断。
        .frame(minWidth: 220, idealWidth: 220, maxWidth: 300, minHeight: 150)
        .fixedSize(horizontal: true, vertical: false)
        .glassSurface(
            .clear,
            contrast: .none,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}
