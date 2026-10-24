import AppKit
import SwiftUI

/// 标注操作条：工具 + 撤销 + 复制 / 保存 / 贴图 / 关闭。
///
/// **两个入口共用这一条**，外观逐像素一致：
/// - 截图后的就地浮层（`SelectionOverlayView`）——压在截图上；
/// - 标注编辑器窗口（`EditorRootView`）——浮在窗口背景上、水平居中、占位不压内容。
///
/// 差异只有三处，全部由参数显式表达：`context`（关闭按钮 / 变换只在编辑器）、
/// `showsCropTool`（浮层的选区本身就是裁剪范围，不再给裁剪）、
/// `showsCloseButton`（编辑器关闭走标题栏红点与 `⌘W`）。
///
/// 参数不常驻：点某个工具会在它下方弹出**该项自己的二级选项**（`ToolOptionsPopover`）。
/// 粗细只有一份（`EditorModel.lineWidth`），各工具按自己的规则换算（见 `EditorToolOptions`），
/// 所以换工具不会丢掉刚调好的粗细。
struct MarkupToolbar: View {
    let model: EditorModel
    let context: MarkupToolbarLayout.Context
    let actions: MarkupActions
    /// 就地浮层不提供裁剪（选区本身就是裁剪范围，再裁一次会让选区与图像坐标错位）；
    /// 裁剪只给编辑器窗口用。
    var showsCropTool: Bool = true
    /// 底部是否带一条分隔线与状态栏（编辑器窗口用）。
    var showsStatusBar: Bool = false

    private typealias Layout = MarkupToolbarLayout

    var body: some View {
        GlassGroup {
            if model.isCropping {
                cluster { cropBar }
            } else if model.isTextPicking {
                cluster { textPickingBar }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Layout.clusterSpacing) {
                        cluster { toolCluster }
                        cluster { actionCluster }
                    }
                    // 窄窗口（编辑器最小 640 pt）放不下一行时改成两行，仍然居中。
                    VStack(spacing: Layout.clusterSpacing) {
                        cluster { toolCluster }
                        cluster { actionCluster }
                    }
                }
            }
        }
    }

    /// 一个玻璃胶囊。它压在任意截图内容上，所以用 `.elevated` 拿到对比基线
    /// （见 `GlassSurface.swift`：最透玻璃不提供底衬，字形要靠语义染色托底）。
    private func cluster<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassSurface(.interactive, contrast: .elevated, in: Capsule())
    }

    private var visibleTools: [EditorTool] {
        Layout.tools(showsCropTool: showsCropTool)
    }

    // MARK: - 模式条

    /// 裁剪模式只留「取消 / 裁剪」：工具与复制 / 保存在裁剪框生效前都会造成误解。
    private var cropBar: some View {
        HStack(spacing: 8) {
            Text(cropSizeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            Button {
                model.cancelCrop()
            } label: {
                Text("取消")
            }
            .glassControlStyle()
            .help("取消裁剪（Esc）")

            Button {
                model.applyCrop()
            } label: {
                Label("裁剪", systemImage: "crop")
            }
            .glassControlStyle(prominent: true)
            .help("应用裁剪（Return）")
        }
    }

    /// 取字模式：只留提示与「完成」，其余按钮都不需要（复制走系统 Live Text 菜单）。
    private var textPickingBar: some View {
        HStack(spacing: 8) {
            Label("拖动选择图中文字，⌘C 复制", systemImage: "text.viewfinder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            Button {
                model.setTextPicking(false)
            } label: {
                Text("完成")
            }
            .glassControlStyle(prominent: true)
            .help("退出取字（Esc）")
        }
    }

    private var cropSizeLabel: String {
        guard let crop = model.cropRect else { return "裁剪" }
        return "\(Int(crop.width)) × \(Int(crop.height)) px"
    }

    // MARK: - 工具胶囊

    private var toolCluster: some View {
        HStack(spacing: Layout.itemSpacing) {
            toolGroup(.drawing)

            if Layout.shows(.enhancement, showsCropTool: showsCropTool) {
                toolGroup(.enhancement)
                    .padding(.leading, Layout.groupExtraGap)
            }

            if context == .editor {
                transformButton
            }

            textPickingButton
            selectedOptionsButton
        }
    }

    /// 一组工具按钮（含各自的二级选项浮窗）；组内用 `itemSpacing`。
    private func toolGroup(_ group: EditorTool.Group) -> some View {
        HStack(spacing: Layout.itemSpacing) {
            ForEach(visibleTools.filter { $0.group == group }) { tool in
                toolButton(tool)
                    .popover(isPresented: optionsBinding(for: tool), arrowEdge: .bottom) {
                        ToolOptionsPopover(
                            model: model,
                            options: EditorToolOptions(tool: tool)
                        )
                    }
            }
        }
    }

    /// 变换（旋转 / 翻转）：一次性图像变换命令，点开与工具二级选项同款的原生浮窗。
    private var transformButton: some View {
        Button {
            model.setOptionsTarget(
                model.optionsTarget == .transform ? nil : .transform
            )
        } label: {
            Image(systemName: "rotate.right")
                .fontWeight(.medium)
                .frame(width: Layout.iconSide, height: Layout.iconSide)
        }
        .glassControlStyle(prominent: model.optionsTarget == .transform)
        .help("旋转与翻转")
        .accessibilityLabel("旋转与翻转")
        .popover(isPresented: transformBinding, arrowEdge: .bottom) {
            transformPopover
        }
    }

    private var transformPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MarkupToolbarLayout.Transform.allCases, id: \.self) { transform in
                Button {
                    model.setOptionsTarget(nil)
                    actions.transform(transform)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: transform.symbolName)
                            .frame(width: 16)
                        Text(transform.title)
                        Spacer(minLength: 12)
                        Text(transform.shortcut)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .accessibilityLabel(transform.title)
            }
        }
        .font(.callout)
        .frame(width: 200, alignment: .leading)
        .padding(14)
    }

    private var textPickingButton: some View {
        Button {
            model.setOptionsTarget(nil)
            model.setTextPicking(true)
        } label: {
            Image(systemName: "text.viewfinder")
                .fontWeight(.medium)
                .frame(width: Layout.iconSide, height: Layout.iconSide)
        }
        .glassControlStyle()
        .help("取字：直接选取图中文字复制（⇧⌘T）")
        .accessibilityLabel("取字")
        .padding(.leading, 4)
    }

    /// 选中已有标注时的「该类型选项」按钮。
    ///
    /// 哪一种类型有选项由 `EditorToolOptions.forKind` 决定（文字 / 打码 / 聚光灯 / 放大镜），
    /// 未在这里的类型就照旧只能移动 / 删除。当前工具本身就是这种类型时不重复出按钮——
    /// 那时点工具图标已经能弹出同一份选项。
    @ViewBuilder private var selectedOptionsButton: some View {
        if let selection = selectedOptions {
            Button {
                model.setOptionsTarget(
                    model.optionsTarget == .selectedAnnotation ? nil : .selectedAnnotation
                )
            } label: {
                Image(systemName: selection.symbol)
                    .fontWeight(.medium)
                    .frame(width: Layout.iconSide, height: Layout.iconSide)
            }
            .glassControlStyle(prominent: model.optionsTarget == .selectedAnnotation)
            .help(selection.help)
            .accessibilityLabel(selection.help)
            .padding(.leading, 4)
            .popover(isPresented: selectedOptionsBinding, arrowEdge: .bottom) {
                ToolOptionsPopover(model: model, options: selection.options)
            }
        }
    }

    private var selectedOptions: (options: EditorToolOptions, symbol: String, help: String)? {
        guard let selected = model.selectedAnnotation,
              let options = EditorToolOptions.forKind(selected.kind) else {
            return nil
        }
        // 当前工具已经能弹出同一份选项时不再多一个按钮。
        guard model.tool.annotationKind != selected.kind else { return nil }
        return (options, symbol(for: selected), "选中\(selected.kind.displayName)的选项")
    }

    /// 按钮图标跟标注类型走；打码额外跟它当前的质感走。
    private func symbol(for annotation: EditorAnnotation) -> String {
        switch annotation.kind {
        case .text: return "textformat"
        case .pixelate, .blur: return annotation.redactionStyle.symbolName
        case .spotlight: return "light.beacon.max"
        case .magnifier: return "plus.magnifyingglass"
        case .rectangle, .ellipse, .line, .arrow, .freehand, .highlighter, .number:
            return "slider.horizontal.3"
        }
    }

    // MARK: - 输出胶囊

    /// 编辑（撤销 / 重做）与输出（复制 / 保存 / 贴图 / 关闭）：同一胶囊内的两个子组。
    private var actionCluster: some View {
        HStack(spacing: MarkupToolbarLayout.clusterSpacing) {
            HStack(spacing: Layout.itemSpacing) {
                iconButton(
                    "arrow.uturn.backward",
                    label: "撤销",
                    help: "撤销（⌘Z）",
                    disabled: !model.canUndo
                ) {
                    model.undo()
                }

                iconButton(
                    "arrow.uturn.forward",
                    label: "重做",
                    help: "重做（⇧⌘Z）",
                    disabled: !model.canRedo
                ) {
                    model.redo()
                }
            }

            HStack(spacing: Layout.itemSpacing) {
                Button(action: actions.copy) {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .glassControlStyle(prominent: true)
                .help(copyHelp)

                Button(action: actions.save) {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .glassControlStyle()
                .help("保存为 PNG（⌘S）")

                iconButton("pin", label: "贴图", help: "贴到屏幕上（⇧⌘P）") {
                    actions.pin()
                }

                if context == .overlay {
                    iconButton("xmark", label: "关闭", help: "关闭；原图已保存到历史（Esc）") {
                        actions.close()
                    }
                }
            }
        }
    }

    /// 复制在两处的语义不同（浮层复制并结束、编辑器复制后留着继续改），提示文案要跟着变。
    private var copyHelp: String {
        switch context {
        case .overlay: return "复制到剪贴板并关闭（Return）"
        case .editor: return "复制到剪贴板（⌘C）"
        }
    }

    // MARK: - 绑定与按钮

    private func optionsBinding(for tool: EditorTool) -> Binding<Bool> {
        Binding(
            get: { model.optionsTarget == .tool(tool) },
            set: { isPresented in
                if isPresented {
                    model.setOptionsTarget(.tool(tool))
                } else if model.optionsTarget == .tool(tool) {
                    model.setOptionsTarget(nil)
                }
            }
        )
    }

    private var transformBinding: Binding<Bool> {
        Binding(
            get: { model.optionsTarget == .transform },
            set: { isPresented in
                if !isPresented, model.optionsTarget == .transform {
                    model.setOptionsTarget(nil)
                }
            }
        )
    }

    private var selectedOptionsBinding: Binding<Bool> {
        Binding(
            get: { model.optionsTarget == .selectedAnnotation },
            set: { isPresented in
                if !isPresented, model.optionsTarget == .selectedAnnotation {
                    model.setOptionsTarget(nil)
                }
            }
        )
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        let isCurrent = tool == model.tool
        return Button {
            // 再点一次已激活的工具 = 煜灯回到「无工具」态。
            // 指针格已经不在操作条上，这是鼠标用户唯一能退出当前工具的路径（键盘走 `V`）。
            // `crop` 不参与：它有自己完整的进 / 出流程（见 `EditorModel.applyCrop` / `cancelCrop`）。
            if isCurrent, tool != .crop {
                model.setTool(.select)
                model.setOptionsTarget(nil)
                return
            }
            // 点击工具 = 选中它 + 弹出它自己的二级选项；无选项的工具（如裁剪）就不弹。
            model.setTool(tool)
            let options = EditorToolOptions(tool: tool)
            model.setOptionsTarget(options.isPresented ? .tool(tool) : nil)
        } label: {
            Image(systemName: tool.symbolName)
                .fontWeight(.medium)
                .frame(width: Layout.iconSide, height: Layout.iconSide)
        }
        // 选中态用强调色玻璃（`.glassProminent`），不靠半透明灰差——最透玻璃下也一眼可辨。
        .glassControlStyle(prominent: isCurrent)
        .help(toolHelp(tool))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// 工具提示：带快捷键，并告诉用户再点一次会退出该工具。
    private func toolHelp(_ tool: EditorTool) -> String {
        let base = tool.shortcut.map { "\(tool.title)（\(String($0).uppercased())）" } ?? tool.title
        guard tool == model.tool, tool != .crop else { return base }
        return "\(base)，再点一次退出"
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .fontWeight(.medium)
                .frame(width: Layout.iconSide, height: Layout.iconSide)
        }
        .glassControlStyle()
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(label)
    }
}
