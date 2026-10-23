import AppKit
import SwiftUI

/// 标注编辑器窗口：**与截图浮层同一条玻璃操作条** + 画布 + 状态栏。
///
/// 以前这里挂的是系统 `NSToolbar`（分段控件、常驻色井与线宽滑块），和截图后那条玻璃胶囊
/// 是两套外观、两套参数呈现，真机上看起来像两个软件。现在工具条换成 `MarkupToolbar`
/// （内容由 `MarkupToolbarLayout` 一处给出），窗口只保留系统标题栏与底部状态栏。
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    /// 贴图目标；为 nil 时「贴图」按钮点了会提示不可用（例如单元测试直接构造控制器）。
    private let pins: PinBoard?
    /// 应用级反馈面板；为 nil 时视图里没有反馈通道（测试直接构造控制器时）。
    private let feedback: FeedbackHUDController?
    var onClose: (() -> Void)?

    init(
        image: CGImage,
        title: String,
        pins: PinBoard? = nil,
        feedback: FeedbackHUDController? = nil
    ) {
        let model = EditorModel(image: image, title: title)
        self.model = model
        self.pins = pins
        self.feedback = feedback

        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑截图"
        window.subtitle = "\(image.width) × \(image.height) px"
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)

        window.contentView = NSHostingView(rootView: rootView())
        window.delegate = self
        model.onImageChange = { [weak self] in
            self?.updateSubtitle()
        }
        window.keyHandler = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.close()
        onClose?()
        onClose = nil
    }

    /// 窗口内容：`EditorRootView`（共用操作条 + 画布 + 状态栏）。
    private func rootView() -> some View {
        EditorRootView(model: model, actions: markupActions(), pins: pins)
            .feedbackHUD(feedback)
    }

    private func markupActions() -> MarkupActions {
        MarkupActions(
            copy: { [weak self] in self?.copyAction() },
            save: { [weak self] in self?.saveAction() },
            pin: { [weak self] in self?.pinAction() },
            close: {},
            transform: { [weak self] transform in
                self?.apply(transform)
            }
        )
    }

    private func apply(_ transform: MarkupToolbarLayout.Transform) {
        switch transform {
        case .rotateClockwise: model.rotate(clockwise: true)
        case .rotateCounterClockwise: model.rotate(clockwise: false)
        case .flipHorizontal: model.flip(horizontal: true)
        case .flipVertical: model.flip(horizontal: false)
        }
    }

    private func updateSubtitle() {
        let size = model.imageSize
        window?.subtitle = "\(Int(size.width)) × \(Int(size.height)) px"
    }

    // MARK: - 键盘

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // 文字输入中：键盘交给字段编辑器，不抢 Delete / Esc / 工具字母。
        if window?.firstResponder is NSTextView {
            return false
        }

        // 裁剪模式：Return 应用、Esc 取消、方向键微调（⇧ 10 px）。其余键不生效。
        if model.isCropping {
            if event.keyCode == 53 {
                model.cancelCrop()
                return true
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                model.applyCrop()
                return true
            }
            if let nudge = Self.cropNudge(for: event) {
                model.nudgeCropRect(dx: nudge.x, dy: nudge.y)
                return true
            }
            return false
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            model.deleteSelected()
            return true
        }

        // 旋转 / 翻转：⌘R 顺时针、⇧⌘R 逆时针、⌃⌘H 水平、⌃⌘V 垂直。
        // 不用 ⌥⌘H：那是系统「隐藏其他」。
        let commandFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if commandFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch key {
            case "r":
                model.rotate(clockwise: !commandFlags.contains(.shift))
                return true
            case "h" where commandFlags.contains(.control):
                model.flip(horizontal: true)
                return true
            case "v" where commandFlags.contains(.control):
                model.flip(horizontal: false)
                return true
            case "p" where commandFlags.contains(.shift):
                pinAction()
                return true
            case "t" where commandFlags.contains(.shift):
                model.setTextPicking(!model.isTextPicking)
                return true
            default:
                break
            }
        }
        if event.keyCode == 53 {
            // 取字模式优先：Esc 先退出取字，再关二级选项浮窗，最后才是取消选中。
            if model.isTextPicking {
                model.setTextPicking(false)
            } else if model.optionsTarget != nil {
                model.setOptionsTarget(nil)
            } else {
                model.clearSelection()
            }
            return true
        }

        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(disallowed).isEmpty,
              let character = event.charactersIgnoringModifiers?.lowercased().first,
              let tool = EditorTool.allCases.first(where: { $0.shortcut == character }) else {
            return false
        }
        model.setTool(tool)
        return true
    }

    private static func cropNudge(for event: NSEvent) -> CGPoint? {
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(disallowed).isEmpty else { return nil }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: return CGPoint(x: -step, y: 0)
        case 124: return CGPoint(x: step, y: 0)
        case 125: return CGPoint(x: 0, y: step)
        case 126: return CGPoint(x: 0, y: -step)
        default: return nil
        }
    }

    // MARK: - 输出

    /// 贴图：把当前渲染结果（含标注）贴成置顶浮动窗口。
    private func pinAction() {
        guard let pins else {
            presentError("当前环境不支持贴图。")
            return
        }
        guard let image = model.renderedImage() else {
            presentError("无法生成编辑后的截图。")
            return
        }
        pins.present(image: image)
        model.statusMessage = "已贴图"
    }

    private func copyAction() {
        guard let image = model.renderedImage() else {
            presentError("无法生成编辑后的截图。")
            return
        }
        do {
            model.statusMessage = try MarkupOutput.copy(image)
        } catch {
            presentError((error as? LocalizedError)?.errorDescription ?? "复制失败。")
        }
    }

    private func saveAction() {
        guard let image = model.renderedImage() else {
            presentError("无法生成编辑后的截图。")
            return
        }
        do {
            if let message = try MarkupOutput.save(image) {
                model.statusMessage = message
            }
        } catch {
            presentError((error as? LocalizedError)?.errorDescription ?? "保存失败。")
        }
    }

    private func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "编辑器操作失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
}

private final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}
