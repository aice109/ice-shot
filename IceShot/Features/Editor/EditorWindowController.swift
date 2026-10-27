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
    /// 历史库：只有它能真正删掉一条历史记录。为 nil 时编辑器不开删除入口。
    private let deleter: (any EditorDeleting)?
    /// 这张图从哪来：决定显不显示删除、能不能删。
    private let target: EditorTarget
    var onClose: (() -> Void)?

    /// 真正的删除入口：来源与依赖都就绪时才提供。
    /// 收藏的图也在这里返回 `nil`：按钮本身就不出现，而不是出现一个点不动的按钮。
    private var deletionTarget: EditorTarget? {
        guard deleter != nil, target.allowsDelete, let recordID = target.recordID else {
            return nil
        }
        return .history(recordID: recordID, isFavorite: false)
    }

    init(
        image: CGImage,
        title: String,
        pins: PinBoard? = nil,
        feedback: FeedbackHUDController? = nil,
        deleter: (any EditorDeleting)? = nil,
        target: EditorTarget = .standalone
    ) {
        // 历史截图没有存来源显示器：按原图尺寸反查当前连接的屏，
        // 拿到菜单栏高度后再对齐设备壳的刘海。反查不到就回退到 14 吋真机值。
        let notchHeight = ScreenGeometry.descriptor(
            matchingPixelSize: CGSize(width: image.width, height: image.height)
        )?.menuBarHeightInUnits(forContentWidth: CGFloat(image.width))
        let model = EditorModel(
            image: image,
            title: title,
            deviceNotchHeightInUnits: notchHeight
        )
        self.model = model
        self.pins = pins
        self.feedback = feedback
        self.deleter = deleter
        self.target = target

        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
            // `.fullSizeContentView` + 透明标题栏：内容一直铺到窗口顶，
            // 标题栏才能是系统液态玻璃的一部分，而不是一条不透明的横条。
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "编辑截图")
        window.titlebarAppearsTransparent = true
        // 标题栏不挡内容：内容从玻璃标题栏之下透上来。
        window.titleVisibility = .hidden
        // 窗口自身不填色，交给 `EditorRootView` 里的玻璃背景与系统合成。
        window.isOpaque = false
        window.backgroundColor = .clear
        window.subtitle = "\(image.width) × \(image.height) px"
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)

        window.contentView = NSHostingView(rootView: rootView())
        window.delegate = self
        // 工具栏保留给窗口级别的动作（删除）：操作条是两个入口共用的，
        // 往里面加「删除」会同时给截图浮层加上一个语义不对的按钮。
        configureToolbar()
        model.onImageChange = { [weak self] in
            self?.updateSubtitle()
        }
        window.keyHandler = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }
    }

    /// 删除按钮的引用：`NSToolbarDelegate` 需要把它交给工具栏。
    private var deleteToolbarItem: NSToolbarItem?

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.close()
        onClose?()
        onClose = nil
    }

    /// 标题栏里的「删除」：只在从历史库打开、且未收藏时出现。
    private func configureToolbar() {
        guard deletionTarget != nil, let window else { return }
        let item = NSToolbarItem(itemIdentifier: .deleteScreenshot)
        item.label = String(localized: "删除")
        item.paletteLabel = String(localized: "删除截图")
        item.toolTip = target.deleteHelp
        item.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: String(localized: "删除截图")
        )
        item.isBordered = true
        item.target = self
        item.action = #selector(deleteScreenshotAction)
        deleteToolbarItem = item

        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
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

        if let command = EditorKeyMapping.command(
            forKeyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) {
            switch command {
            case .deleteScreenshot:
                requestDelete()
            case .deleteSelectedAnnotation:
                model.deleteSelected()
            }
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
            case "b" where commandFlags.contains(.shift) == false && commandFlags.contains(.control) == false:
                // ⌘B 快速开关带壳：只切换开关，详细样式在 popover 里调。
                model.setFrameEnabled(!model.isFrameEnabled)
                return true
            case "t" where commandFlags.contains(.shift):
                model.setTextPicking(!model.isTextPicking)
                return true
            default:
                break
            }
        }

        // ⌘⌫ = 删除这张历史截图；映射见 `EditorKeyMapping`（必须先于裸 ⌫ 判定）。
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

    /// 贴图：把当前导出结果（标注 + 可选窗口壳）贴成置顶浮动窗口。
    private func pinAction() {
        guard let pins else {
            presentError(String(localized: "当前环境不支持贴图。"))
            return
        }
        guard let image = model.exportImage() else {
            presentError(String(localized: "无法生成编辑后的截图。"))
            return
        }
        pins.present(image: image)
        model.statusMessage = String(localized: "已贴图")
    }

    private func copyAction() {
        guard let image = model.exportImage() else {
            presentError(String(localized: "无法生成编辑后的截图。"))
            return
        }
        do {
            model.statusMessage = try MarkupOutput.copy(image)
        } catch {
            presentError((error as? LocalizedError)?.errorDescription ?? String(localized: "复制失败。"))
        }
    }

    private func saveAction() {
        guard let image = model.exportImage() else {
            presentError(String(localized: "无法生成编辑后的截图。"))
            return
        }
        do {
            if let message = try MarkupOutput.save(image) {
                model.statusMessage = message
            }
        } catch {
            presentError((error as? LocalizedError)?.errorDescription ?? String(localized: "保存失败。"))
        }
    }

    // MARK: - 删除

    @objc private func deleteScreenshotAction() {
        requestDelete()
    }

    /// 删除前的完整流程：确认 → 调库 → 关窗。
    ///
    /// 不可删的状态（截图进编辑器 / 收藏的图）通过 `⌘⌫` 进来时，要明确告知原因，
    /// 不能默默无反应——用户会以为快捷键坏了。
    private func requestDelete() {
        guard let deletionTarget else {
            model.statusMessage = deletionBlockedMessage
            return
        }
        guard let deleter, let recordID = deletionTarget.recordID, let window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "删除这张截图？")
        alert.informativeText = String(localized: "原图与缩略图会从历史库删除，无法恢复。")
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        // 默认按钮是「删除」：回车就删不是好默认，把焦点放到「取消」上。
        alert.window.initialFirstResponder = alert.buttons.last

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(recordID: recordID, using: deleter)
        }
    }

    /// 不可删时的说明：状态栏一句话，不带弹窗（快捷键误按不该被打断）。
    private var deletionBlockedMessage: String {
        switch target {
        case .standalone:
            return String(localized: "这张图不在历史库里，没有可删除的记录（关闭窗口即可）")
        case .history(_, let isFavorite) where isFavorite:
            return String(localized: "已收藏的截图不会被自动清理，请先取消收藏再删除")
        case .history:
            return String(localized: "当前无法删除")
        }
    }

    private func performDelete(recordID: UUID, using deleter: any EditorDeleting) {
        Task { [weak self] in
            guard let self else { return }
            do {
                // `false` = 记录已经不在了（被别处删过 / 被清理策略清掉），按已删掉处理。
                _ = try await deleter.deleteRecord(id: recordID)
                self.model.statusMessage = String(localized: "已删除")
                self.window?.close()
            } catch {
                self.presentError(
                    (error as? LocalizedError)?.errorDescription
                        ?? "删除失败（错误码 \((error as NSError).code)）。"
                )
            }
        }
    }

    private func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "编辑器操作失败")
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

// MARK: - 工具栏

private extension NSToolbarItem.Identifier {
    static let deleteScreenshot = NSToolbarItem.Identifier("EditorDeleteScreenshot")
}

extension EditorWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if let item = deleteToolbarItem {
            return [.flexibleSpace, item.itemIdentifier, .flexibleSpace]
        }
        return []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        deleteToolbarItem.map { [$0.itemIdentifier, .flexibleSpace] } ?? [.flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .deleteScreenshot else { return nil }
        return deleteToolbarItem
    }
}
