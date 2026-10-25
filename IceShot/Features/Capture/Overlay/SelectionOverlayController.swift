import AppKit
import SwiftUI

@MainActor
final class SelectionOverlayController: SelectionOverlayPresenting {
    private struct Session {
        let displayFrame: DisplayFrame
        /// 模型图在显示器局部坐标中的位置（points）。
        let imageFrame: CGRect
        /// 模型图（区域截图时是整帧，预设选区时是选区图像）。
        let image: CGImage
        /// 区域截图允许在编辑态继续调整选区；预设选区锁定。
        let allowsAdjustment: Bool
    }

    private var panels: [CaptureOverlayPanel] = []
    private var panelsByDisplayID: [CGDirectDisplayID: CaptureOverlayPanel] = [:]
    private var overlayState: SelectionOverlayState?
    private var framesByDisplayID: [CGDirectDisplayID: DisplayFrame] = [:]
    private var keyMonitor: Any?
    private var onFinish: ((SelectionFinish) -> Void)?
    /// 点中高亮窗口的回调；空目录（长截图 / 预设选区）时永远不会触发。
    private var onWindowPick: ((WindowDescriptor) -> Void)?
    private var windows: [WindowDescriptor] = []
    /// 松手后是否进入就地标注；长截图走 false（选区即抓取范围，直接开始采集）。
    private var autoEditOnSelection = true
    private var onCancel: (() -> Void)?
    private var isFinishing = false
    /// 同一个 Esc 只处理一次：多层入口（监听 / SwiftUI / 窗口）都会调 `handleEscape()`。
    private var escapeGate = EscapeGate()
    private var session: Session?
    /// 浮层内的短反馈（如取字复制条码）走应用级 HUD，不在地基视图里自绘。
    private let feedback: FeedbackHUDController?

    init(feedback: FeedbackHUDController? = nil) {
        self.feedback = feedback
    }

    func present(
        frames: [DisplayFrame],
        preset: SelectionPreset?,
        autoEditOnSelection: Bool = true,
        windows: [WindowDescriptor] = [],
        onWindowPick: @escaping (WindowDescriptor) -> Void,
        onFinish: @escaping (SelectionFinish) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.autoEditOnSelection = autoEditOnSelection
        self.windows = windows
        self.onWindowPick = onWindowPick

        let overlayState = SelectionOverlayState()
        self.overlayState = overlayState
        framesByDisplayID.removeAll()
        for frame in frames {
            framesByDisplayID[frame.display.id] = frame
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }

        for frame in frames {
            let view = SelectionOverlayView(
                frame: frame,
                state: overlayState,
                windows: windows,
                onSelectionReady: { [weak self] displayID, rect in
                    guard let self else { return }
                    if self.autoEditOnSelection {
                        self.beginRegionEditing(displayID: displayID, rect: rect)
                    } else {
                        self.beginRegionEditing(displayID: displayID, rect: rect)
                        self.finish(.copy)
                    }
                },
                onWindowPick: { [weak self] window in
                    self?.onWindowPick?(window)
                },
                onAction: { [weak self] action in
                    self?.finish(action)
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
            panel.onCancelOperation = { [weak self] in
                self?.handleEscape()
            }
            panel.onTextPickingEscape = { [weak self] in
                self?.exitTextPickingIfNeeded() ?? false
            }
            // 指针位置由面板级监视器实时上报：不依赖 SwiftUI hover 的追踪区，
            // 指针停在手柄 / 工具条 / 层间空隙上也能正常跟手（见 `CaptureOverlayPanel`）。
            let displayID = frame.display.id
            panel.onPointerMoved = { [weak overlayState] point in
                overlayState?.updatePointer(point, displayID: displayID)
            }
            panel.startPointerTracking()
            panel.contentView = FirstMouseHostingView(
                rootView: AnyView(view.feedbackHUD(feedback))
            )
            panel.setFrame(frame.display.appKitFrame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
            panelsByDisplayID[frame.display.id] = panel
        }

        if let preset {
            beginPresetEditing(preset)
            panelsByDisplayID[preset.displayID]?.makeKey()
        } else {
            let cursor = NSEvent.mouseLocation
            // 边界点也要算进去：指针恰好压在屏幕最上一行 / 最右一列时，
            // `CGRect.contains` 的半开区间会把它判成「哪块屏都不是」。
            if let keyPanel = panels.first(where: {
                OverlayCoordinates.containsInclusive($0.frame, cursor)
            }) {
                keyPanel.makeKey()
            } else {
                panels.first?.makeKey()
            }
        }

        // 首帧播种：浮层出现时指针已经停在某处，而指针不动就不会有鼠标移动事件；
        // 不先写一次的话，框选前的那一格光标要等用户移一下鼠标才正确。
        // 换算与面板鼠标监视器 / `SelectionOverlayView` 共用 `OverlayCoordinates`。
        for frame in frames {
            guard let point = OverlayCoordinates.viewPoint(
                fromScreen: NSEvent.mouseLocation,
                displayFrame: frame.display.appKitFrame
            ) else { continue }
            overlayState.updatePointer(point, displayID: frame.display.id)
        }
    }

    func dismiss() {
        for panel in panels {
            panel.allowsClose = true
            panel.stopPointerTracking()
            panel.onPointerMoved = nil
            panel.orderOut(nil)
            panel.close()
            panel.contentView = nil
        }
        panels.removeAll()
        panelsByDisplayID.removeAll()
        overlayState?.setSpacePressed(false)
        overlayState = nil
        framesByDisplayID.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        onFinish = nil
        onCancel = nil
        onWindowPick = nil
        windows.removeAll()
        isFinishing = false
        escapeGate = EscapeGate()
        session = nil
        NSColorPanel.shared.close()
        NSColorPanel.shared.level = .floating
    }

    // MARK: - 进入编辑

    private func beginRegionEditing(displayID: CGDirectDisplayID, rect: CGRect) {
        guard let frame = framesByDisplayID[displayID],
              rect.width >= 1, rect.height >= 1 else {
            return
        }
        let imageFrame = CGRect(origin: .zero, size: frame.display.pointSize)
        beginEditing(
            displayID: displayID,
            rect: rect,
            image: frame.image,
            imageFrame: imageFrame,
            allowsAdjustment: true
        )
    }

    private func beginPresetEditing(_ preset: SelectionPreset) {
        beginEditing(
            displayID: preset.displayID,
            rect: preset.rect,
            image: preset.image,
            imageFrame: preset.rect,
            allowsAdjustment: false
        )
    }

    private func beginEditing(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        image: CGImage,
        imageFrame: CGRect,
        allowsAdjustment: Bool
    ) {
        guard let frame = framesByDisplayID[displayID],
              let overlayState else {
            return
        }
        session = Session(
            displayFrame: frame,
            imageFrame: imageFrame,
            image: image,
            allowsAdjustment: allowsAdjustment
        )
        overlayState.update(displayID: displayID, rect: rect)
        overlayState.beginEditing(
            editor: EditorModel(image: image, title: "截图"),
            imageFrame: imageFrame,
            allowsAdjustment: allowsAdjustment
        )
        panelsByDisplayID[displayID]?.makeKey()
    }

    // MARK: - 键盘

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let overlayState else { return event }

        if event.type == .keyDown, event.keyCode == 53 {
            EscapeTrace.log(
                "monitor",
                "textPicking=\(overlayState.editor?.isTextPicking == true)"
                    + " options=\(overlayState.editor?.optionsTarget != nil)"
                    + " editing=\(overlayState.isEditing)"
                    + " textView=\(self.panels.contains(where: { $0.firstResponder is NSTextView }))"
                    + " colorPanel=\(NSColorPanel.shared.isKeyWindow)"
            )
        }

        // 系统颜色面板在前台：键盘归它（Esc 关面板、输入 HEX / RGB），
        // 否则面板级监听会把 Esc / Return / 工具字母抢走。
        if NSColorPanel.shared.isKeyWindow {
            return event
        }

        // 文字输入中：键盘交给 NSTextField 的字段编辑器，
        // 否则 Esc / Return / 工具字母会被面板级监听先吃掉。
        // 例外是取字模式：Live Text 的文本选择视图本身也是 NSTextView，放它自己处理时
        // Esc 会一路冒泡到浮层视图，把整次截图关掉——这里改成「退出取字、回到编辑态」。
        if panels.contains(where: { $0.firstResponder is NSTextView }) {
            if event.type == .keyDown, event.keyCode == 53 {
                return handleEscape()
            }
            return event
        }

        if overlayState.isEditing {
            return handleEditingKey(event, state: overlayState)
        }

        if event.keyCode == 49 { // Space：选区阶段用于拖移已有选区
            if !event.isARepeat {
                overlayState.setSpacePressed(event.type == .keyDown)
            }
            return nil
        }

        guard event.type == .keyDown else {
            return event
        }

        if event.keyCode == 53 { // Esc
            cancel()
            return nil
        }
        return event
    }

    private func handleEditingKey(
        _ event: NSEvent,
        state: SelectionOverlayState
    ) -> NSEvent? {
        if event.keyCode == 49, state.allowsAdjustment { // Space：按住时拖移选区
            // 重复 keyDown 不解状态：长按时系统每秒派发十几条，
            // 每次都赋值虽然已经被 `setSpacePressed` 去重，但没必要白跑。
            // 真正的响铃问题在 `FirstMouseHostingView.keyDown`——那里把 Space
            // 从 SwiftUI 键盘系统手里截下来，见该类的注释。
            if !event.isARepeat {
                state.setSpacePressed(event.type == .keyDown)
            }
            return nil
        }

        guard event.type == .keyDown else {
            return event
        }

        // 取字模式：Esc 退出取字，其余按键（⌘C 等）原样交给系统 Live Text。
        if state.editor?.isTextPicking == true {
            if event.keyCode == 53 {
                return handleEscape()
            }
            return event
        }

        switch event.keyCode {
        case 53: // Esc：先退模式（取字 / 二级选项），其次关闭（历史里仍保留原图）
            return handleEscape()
        case 36, 76: // Return / 小键盘 Enter
            finish(.copy)
            return nil
        case 51, 117: // Delete / Forward Delete
            state.editor?.deleteSelected()
            return nil
        default:
            break
        }

        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            switch characters {
            case "z":
                if flags.contains(.shift) {
                    state.editor?.redo()
                } else {
                    state.editor?.undo()
                }
                return nil
            case "c":
                finish(.copy)
                return nil
            case "s":
                finish(.save)
                return nil
            case "p" where flags.contains(.shift):
                finish(.pin)
                return nil
            case "t" where flags.contains(.shift):
                state.editor?.setTextPicking(true)
                return nil
            default:
                return event
            }
        }

        if flags.contains(.option) || flags.contains(.control) {
            return event
        }

        guard let character = characters.first,
              let tool = EditorTool.allCases.first(where: { $0.shortcut == character }),
              // 就地浮层不提供裁剪工具（选区已经是裁剪范围）。
              tool != .crop else {
            return event
        }
        state.editor?.setTool(tool)
        return nil
    }

    /// 取字模式的 Esc 兜底：`performKeyEquivalent` 层只认这一种情况。
    private func exitTextPickingIfNeeded() -> Bool {
        guard overlayState?.editor?.isTextPicking == true else { return false }
        // 同一个按键若已被面板级监听处理过，这里只算「已消费」，不再动状态。
        guard escapeGate.shouldHandle(at: ProcessInfo.processInfo.systemUptime) else { return true }
        overlayState?.editor?.setTextPicking(false)
        return true
    }

    /// 统一 Esc：四层入口（面板级监听 / `performKeyEquivalent` / 浮层 `onKeyPress` /
    /// `cancelOperation`）都收在 `EditorEscapeAction` 这一套优先级上。
    /// 返回 `nil` 表示这次按键已被消费。
    @discardableResult
    private func handleEscape() -> NSEvent? {
        guard let overlayState else { return nil }
        guard escapeGate.shouldHandle(at: ProcessInfo.processInfo.systemUptime) else {
            EscapeTrace.log("escape.duplicate")
            return nil
        }
        let action = EditorEscapeAction.resolve(
            editor: overlayState.editor,
            isEditing: overlayState.isEditing
        )
        EscapeTrace.log("escape.resolve", "\(action)")
        switch action {
        case .exitTextPicking:
            overlayState.editor?.setTextPicking(false)
        case .closeOptions:
            overlayState.editor?.setOptionsTarget(nil)
        case .closeEditing:
            finish(.close)
        case .cancelCapture:
            cancel()
        }
        return nil
    }

    // MARK: - 收尾

    private func finish(_ action: MarkupAction) {
        EscapeTrace.log("finish", "\(action)")
        guard !isFinishing,
              let session,
              let overlayState,
              let rect = validSelection(overlayState) else {
            return
        }
        isFinishing = true

        let original = croppedImage(session, rect: rect)
        let output: CGImage?
        switch action {
        case .close:
            output = nil
        case .copy, .save, .pin:
            output = outputImage(session: session, state: overlayState, rect: rect)
        }

        let result = SelectionResult(frame: session.displayFrame, rect: rect)
        let callback = onFinish
        dismiss()
        // dismiss() 会复位 isFinishing；保持到下一次 present，避免重复收尾。
        isFinishing = true
        guard let original else {
            return
        }
        callback?(
            SelectionFinish(
                result: result,
                original: original,
                output: output,
                action: action
            )
        )
    }

    private func outputImage(
        session: Session,
        state: SelectionOverlayState,
        rect: CGRect
    ) -> CGImage? {
        guard let editor = state.editor else {
            return croppedImage(session, rect: rect)
        }
        if editor.annotations.isEmpty {
            return croppedImage(session, rect: rect)
        }
        guard let rendered = editor.renderedImage() else {
            return croppedImage(session, rect: rect)
        }
        return cropPixels(of: rendered, session: session, rect: rect)
    }

    private func validSelection(_ state: SelectionOverlayState) -> CGRect? {
        let rect = state.rect
        guard rect.width >= 1, rect.height >= 1,
              state.activeDisplayID != nil else {
            return nil
        }
        return rect
    }

    /// 把显示器局部 points 选区换算成模型图上的像素矩形。
    private func pixelRect(for session: Session, rect: CGRect) -> CGRect? {
        let imageFrame = session.imageFrame
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let scaleX = CGFloat(session.image.width) / imageFrame.width
        let scaleY = CGFloat(session.image.height) / imageFrame.height
        let pixel = CGRect(
            x: ((rect.minX - imageFrame.minX) * scaleX).rounded(),
            y: ((rect.minY - imageFrame.minY) * scaleY).rounded(),
            width: (rect.width * scaleX).rounded(),
            height: (rect.height * scaleY).rounded()
        )
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: session.image.width,
            height: session.image.height
        )
        let clipped = pixel.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            return nil
        }
        return clipped
    }

    private func croppedImage(_ session: Session, rect: CGRect) -> CGImage? {
        guard let pixelRect = pixelRect(for: session, rect: rect) else { return nil }
        // 矩形已校验为 ≥1 px 且落在图像内，裁切失败只会是 Core Graphics 异常，按无结果处理。
        guard let cropped = try? ImageCropper.crop(session.image, to: pixelRect) else {
            return nil
        }
        return cropped
    }

    private func cropPixels(
        of image: CGImage,
        session: Session,
        rect: CGRect
    ) -> CGImage? {
        guard let pixelRect = pixelRect(for: session, rect: rect) else { return nil }
        guard let cropped = try? ImageCropper.crop(image, to: pixelRect) else {
            return nil
        }
        return cropped
    }

    private func cancel() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}
