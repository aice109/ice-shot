import AppKit
import SwiftUI

/// 单块屏幕上的窗口选择浮层。
///
/// 显示冻结帧 + 压暗遮罩，鼠标悬停时高亮窗口并显示窗口名；
/// 点击或 Return 确认，右键 / Esc 取消。每块屏幕一个实例，悬停状态由共享的
/// `WindowHoverState` 同步，避免多屏之间出现两个高亮。
struct WindowSelectionOverlayView: View {
    let frame: DisplayFrame
    let windows: [WindowDescriptor]
    let state: WindowHoverState
    let onPick: (WindowDescriptor) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    private var hoveredWindow: WindowDescriptor? {
        guard let id = state.windowID else { return nil }
        return windows.first { $0.id == id }
    }

    private var highlightRect: CGRect? {
        guard let window = hoveredWindow else { return nil }
        return WindowHoverPicker.highlightRect(for: window, display: frame.display)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.image, scale: frame.display.scale)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size.width, height: size.height)

                DimmingOverlay(selection: highlightRect ?? .zero)
                    .allowsHitTesting(false)

                if let rect = highlightRect, let window = hoveredWindow {
                    WindowHighlight(
                        rect: rect,
                        name: window.displayName,
                        bounds: size
                    )
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(pickGesture)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHover(at: location)
                        case .ended:
                            state.clear(displayID: frame.display.id)
                        }
                    }

                VStack {
                    Spacer()
                    Text("点击选择窗口 · 右键 / Esc 取消")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassSurface(.clear, contrast: .none, in: Capsule())
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear {
                isFocused = true
                if OverlayCoordinates.containsInclusive(
                    frame.display.appKitFrame,
                    NSEvent.mouseLocation
                ) {
                    updateHover(at: currentMouseLocalPoint())
                }
            }
            .onKeyPress { press in
                switch press.key {
                case .escape:
                    onCancel()
                    return .handled
                case .return:
                    if let window = hoveredWindow {
                        onPick(window)
                        return .handled
                    }
                    return .ignored
                default:
                    return .ignored
                }
            }
        }
    }

    private var pickGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                updateHover(at: value.location)
            }
            .onEnded { value in
                updateHover(at: value.location)
                if let window = hitTest(at: value.location) {
                    onPick(window)
                }
            }
    }

    private func updateHover(at point: CGPoint) {
        let window = hitTest(at: point)
        state.update(windowID: window?.id, displayID: frame.display.id)
    }

    private func hitTest(at point: CGPoint) -> WindowDescriptor? {
        WindowHoverPicker.window(
            atLocalPoint: point,
            display: frame.display,
            windows: windows
        )
    }

    private func currentMouseLocalPoint() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(
            x: mouse.x - frame.display.appKitFrame.minX,
            y: frame.display.appKitFrame.maxY - mouse.y
        )
    }

}
