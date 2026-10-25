import AppKit
import Observation
import SwiftUI

/// 长截图进行中的提示条：显示已采集帧数 / 高度，并提供「完成 / 取消」。
///
/// 不用键盘收尾：采集期间用户要去被截的 App 里滚动，IceShot 不是前台，
/// 本地快捷键监听收不到 `Return`，全局监听又要申请输入监控权限。
/// 所以按钮 + 再按一次长截图快捷键（由 `CaptureCoordinator` 处理）结束。
@MainActor
@Observable
final class ScrollCaptureState {
    var frameCount = 0
    var height = 0
    var message: String?
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
}

@MainActor
final class ScrollCaptureHUDController {
    private var panel: NSPanel?
    private var state: ScrollCaptureState?

    func present(
        near point: CGPoint,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        let state = ScrollCaptureState()
        state.onFinish = onFinish
        state.onCancel = onCancel
        self.state = state

        let size = NSSize(width: 340, height: 116)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.contentView = FirstMouseHostingView(
            rootView: AnyView(ScrollCaptureHUDView(state: state))
        )

        // 放在选区上方居中；越界时夹回鼠标所在屏幕的可见区域。
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: min(max(point.x - size.width / 2, visible.minX + 12), visible.maxX - size.width - 12),
            y: min(max(point.y + 16, visible.minY + 12), visible.maxY - size.height - 12)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(_ status: ScrollCaptureSession.Status) {
        guard let state else { return }
        state.frameCount = status.frameCount
        state.height = status.height
        state.message = status.message
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        state = nil
    }
}

private struct ScrollCaptureHUDView: View {
    let state: ScrollCaptureState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scroll")
                    .foregroundStyle(.tint)
                Text("长截图采集中")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("已采集 \(state.frameCount) 帧 · \(state.height) px")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(state.message ?? "先点一下要截的窗口，再在里面向下滚动；完成后点「完成」")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") {
                    state.onCancel()
                }
                .buttonStyle(.bordered)
                Button("完成") {
                    state.onFinish()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 340)
        .glassSurface(.clear, contrast: .none, in: RoundedRectangle(cornerRadius: 12))
        .padding(4)
    }
}
