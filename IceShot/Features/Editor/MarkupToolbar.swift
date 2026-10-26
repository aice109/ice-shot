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
    /// 「带壳」预览的内容图。编辑器窗口给整张标注结果；浮层要先按选区裁剪。
    var frameContent: (() -> CGImage?)? = nil

    private typealias Layout = MarkupToolbarLayout

    var body: some View {
        // `spacing` 略大于 `clusterSpacing`：两组胶囊在贴合时能真实融成一体（液态吸附），
        // 又不会因为距离过近而粘成一坨。低于 26 时它只是个普通容器，值无副作用。
        GlassGroup(spacing: 12) {
            if model.isCropping {
                cluster { cropBar }
                    .glassMorphID(Self.barMorphID, in: glassNamespace)
            } else if model.isTextPicking {
                cluster { textPickingBar }
                    .glassMorphID(Self.barMorphID, in: glassNamespace)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Layout.clusterSpacing) {
                        cluster { toolCluster }
                            .glassMorphID(Self.toolBarMorphID, in: glassNamespace)
                        cluster { actionCluster }
                            .glassMorphID(Self.actionBarMorphID, in: glassNamespace)
                    }
                    // 窄窗口（编辑器最小 640 pt）放不下一行时改成两行，仍然居中。
                    VStack(spacing: Layout.clusterSpacing) {
                        cluster { toolCluster }
                            .glassMorphID(Self.toolBarMorphID, in: glassNamespace)
                        cluster { actionCluster }
                            .glassMorphID(Self.actionBarMorphID, in: glassNamespace)
                    }
                }
            }
        }
    }

    /// 玻璃形状变形的公共命名空间：同 id 的玻璃在增删时互相流动。
    @Namespace private var glassNamespace

    /// 带壳 popover 的展开状态。放在视图本地：它不是工具，不参与 `optionsTarget` 的互斥。
    @State private var isFramePopoverPresented = false

    // 模式条的 id 与工具条区分开：裁剪 / 取字是「整条替换」，
    // 和工具条 ↔ 动作条那种「半条变化」不是同一次变形。
    private static let barMorphID = "toolbar-mode-bar"
    private static let toolBarMorphID = "toolbar-tools"
    private static let actionBarMorphID = "toolbar-actions"

    /// 一个玻璃胶囊。压在任意截图内容上，用最透的 `.clear`——
    /// 液态玻璃的强度由系统设置决定，应用不额外染色托底。
    private func cluster<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassSurface(.clear, contrast: .none, in: Capsule())
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
        guard let crop = model.cropRect else { return String(localized: "裁剪") }
        return "\(Int(crop.width)) × \(Int(crop.height)) px"
    }

    // MARK: - 工具胶囊

    /// 按 `MarkupToolbarLayout.toolCluster` 的顺序渲染工具胶囊。
    ///
    /// 三种格子：独占工具（箭头 / 文字 / 马赛克 / 裁剪）、多子型组（形状 / 画笔）、
    /// 「更多」（展开后在其中就地插入 序号 / 聚光灯 / 放大镜）。
    private var toolCluster: some View {
        HStack(spacing: Layout.itemSpacing) {
            ForEach(Array(Layout.items(
                in: context,
                showsCropTool: showsCropTool,
                hasSelectedAnnotationOptions: selectedOptions != nil
            ).enumerated()), id: \.offset) { _, item in
                view(for: item)
            }
        }
    }

    @ViewBuilder
    private func view(for item: Layout.Item) -> some View {
        switch item {
        case .tool(let tool):
            toolButton(tool)
        case .group(let group):
            groupCluster(group)
        case .transform:
            transformButton
        case .textPicking:
            textPickingButton
        case .selectedOptions:
            selectedOptionsButton
        }
    }

    /// 多子型组按钮 + （形状 / 画笔的）子型切换浮窗；「更多」额外就地展开成员格。
    ///
    /// 「更多」展开时成员插在**按钮左边**：它在工具序列的最后，往右插会顶出胶囊边界。
    /// 成员与其余工具之间加一条竖线——这是「容器」与「工具」在形态上的第二重信号
    /// （第一重是胶囊按钮本身）。
    @ViewBuilder
    private func groupCluster(_ group: EditorTool.ToolGroup) -> some View {
        HStack(spacing: Layout.itemSpacing) {
            if group == .more, model.isMoreExpanded {
                ForEach(group.members) { tool in
                    toolButton(tool)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))

                ContainerDivider()
            }

            groupButton(group)
        }
        // 其余两组共用一份子型 + 参数浮窗，挂在组按钮上。
        .popover(isPresented: groupOptionsBinding(group), arrowEdge: .bottom) {
            ToolOptionsPopover(
                model: model,
                options: options(for: group),
                subOptions: group == .more ? [] : group.members
            )
        }
    }

    /// 组按钮当前代表的工具：已在该组内就用当前的，熄灯后回到「上次用的那个」。
    private func representedTool(_ group: EditorTool.ToolGroup) -> EditorTool {
        if let current = model.tool.toolGroup, current == group {
            return model.tool
        }
        return model.lastTool(in: group)
    }

    @ViewBuilder
    private func groupButton(_ group: EditorTool.ToolGroup) -> some View {
        // 「更多」是**容器**不是工具：形态（胶囊 + 箭头）、交互（纯开关）、高亮语义
        // （只在展开时亮）三处都与旁边的工具格不同。混成一样会让人以为点它会画东西。
        if group == .more {
            moreButton()
        } else {
            toolGroupButton(group)
        }
    }

    /// 「更多」：胶囊形 + 旋转箭头，点一下就地展开 / 收起成员格。
    private func moreButton() -> some View {
        Button {
            withAnimation(Self.moreExpandAnimation) {
                model.setMoreExpanded(!model.isMoreExpanded)
            }
        } label: {
            Image(systemName: Layout.moreSymbolName)
                .font(.caption.weight(.semibold))
                // 展开后成员插在按钮**左边**，所以箭头指向左 = 「点它收回去」。
                // `chevron.right` 转 180° 正好朝左；转 90° 会变成下箭头，方向感是错的。
                .rotationEffect(.degrees(model.isMoreExpanded ? 180 : 0))
                .frame(width: Layout.iconSide, height: Layout.iconSide)
                .padding(.horizontal, Layout.moreButtonHorizontalPadding)
                .frame(height: Layout.moreButtonHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassControlStyle(prominent: model.isMoreExpanded, clear: true)
        .help(model.isMoreExpanded ? "收起更多工具" : "更多工具")
        .accessibilityLabel(model.isMoreExpanded ? "收起更多工具" : "更多工具")
        .accessibilityAddTraits(model.isMoreExpanded ? [.isSelected] : [])
    }

    /// 形状 / 画笔：一格承载组内多个工具，图标跟「当前或上次用的子型」走。
    private func toolGroupButton(_ group: EditorTool.ToolGroup) -> some View {
        let represented = representedTool(group)
        let isCurrent = represented == model.tool
        return Button {
            // 再点一次当前组内工具 = 熄灯回「无工具」；想换子型请在浮窗里点另一项。
            if isCurrent {
                model.setTool(.select)
                model.setOptionsTarget(nil)
                return
            }
            model.setTool(represented)
            let options = options(for: group)
            model.setOptionsTarget(options.isPresented ? .tool(represented) : nil)
        } label: {
            iconOnly(symbol: represented.symbolName)
        }
        // 高亮＝「当前工具在这个组里」，与旁边的单工具格同一条语义。
        .glassControlStyle(prominent: isCurrent, clear: true)
        .help(groupHelp(group, represented: represented))
        .accessibilityLabel(groupHelp(group, represented: represented))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// 「更多」展开 / 收起的动效：它是空间变化，瞬变会像渲染 bug。
    private static let moreExpandAnimation: Animation = .snappy(duration: 0.18)

    /// 组按钮的二级选项：形状 / 画笔按「当前代表的那件工具」取参数，更多三项各弹自己的。
    private func options(for group: EditorTool.ToolGroup) -> EditorToolOptions {
        EditorToolOptions(tool: representedTool(group))
    }

    private func groupOptionsBinding(_ group: EditorTool.ToolGroup) -> Binding<Bool> {
        Binding(
            get: {
                guard group != .more else { return false }
                return model.optionsTarget == .tool(representedTool(group))
            },
            set: { isPresented in
                guard group != .more else { return }
                let target = EditorModel.OptionsTarget.tool(representedTool(group))
                if isPresented {
                    model.setOptionsTarget(target)
                } else if model.optionsTarget == target {
                    model.setOptionsTarget(nil)
                }
            }
        )
    }

    /// 组按钮提示：带快捷键，并交代「点下去会画什么」和「子型在哪换」。
    private func groupHelp(_ group: EditorTool.ToolGroup, represented: EditorTool) -> String {
        let base: String
        switch group {
        case .shape: base = "形状：当前「\(represented.title)」"
        case .brush: base = "画笔：当前「\(represented.title)」"
        case .more: return model.isMoreExpanded ? String(localized: "收起更多工具") : String(localized: "更多工具")
        }
        let shortcut = represented.shortcut.map { "（\(String($0).uppercased())）" } ?? ""
        guard represented == model.tool else {
            return "\(base)\(shortcut)，点开可换子型、调参数"
        }
        return "\(base)\(shortcut)，再点一次退出"
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
        .glassControlStyle(prominent: model.optionsTarget == .transform, clear: true)
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
            .glassControlStyle(prominent: model.optionsTarget == .selectedAnnotation, clear: true)
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
                    label: String(localized: "撤销"),
                    help: String(localized: "撤销（⌘Z）"),
                    disabled: !model.canUndo
                ) {
                    model.undo()
                }

                iconButton(
                    "arrow.uturn.forward",
                    label: String(localized: "重做"),
                    help: String(localized: "重做（⇧⌘Z）"),
                    disabled: !model.canRedo
                ) {
                    model.redo()
                }
            }

            HStack(spacing: Layout.itemSpacing) {
                frameButton

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

    /// 带壳：输出前的最后一个视觉设置。按钮高亮表示「复制 / 保存 / 贴图会带上壳」。
    private var frameButton: some View {
        Button {
            isFramePopoverPresented.toggle()
        } label: {
            iconOnly(symbol: "macwindow")
        }
        .glassControlStyle(prominent: model.isFrameEnabled, clear: true)
        .help(model.isFrameEnabled ? "带壳已开启（⌘B 关闭）" : "带壳：给截图加 macOS 窗口壳（⌘B）")
        .accessibilityLabel("带壳")
        .accessibilityAddTraits(model.isFrameEnabled ? [.isSelected] : [])
        .popover(isPresented: $isFramePopoverPresented, arrowEdge: .bottom) {
            ScreenshotFramePopover(model: model, content: frameContent)
        }
    }

    /// 复制在两处的语义不同（浮层复制并结束、编辑器复制后留着继续改），提示文案要跟着变。
    private var copyHelp: String {
        switch context {
        case .overlay: return String(localized: "复制到剪贴板并关闭（Return）")
        case .editor: return String(localized: "复制到剪贴板（⌘C）")
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
        let options = EditorToolOptions(tool: tool)
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
            model.setOptionsTarget(options.isPresented ? .tool(tool) : nil)
        } label: {
            iconOnly(symbol: tool.symbolName)
        }
        // 选中态用强调色玻璃（`.glassProminent`），不靠半透明灰差——最透玻璃下也一眼可辨。
        .glassControlStyle(prominent: isCurrent, clear: true)
        .help(toolHelp(tool))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .popover(isPresented: optionsBinding(for: tool), arrowEdge: .bottom) {
            ToolOptionsPopover(model: model, options: options)
        }
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
            iconOnly(symbol: symbol)
        }
        .glassControlStyle()
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(label)
    }

    /// 工具/动作按钮的统一内容：**只有一个图标**。
    ///
    /// 固定 `Layout.iconSide` 见方，保证所有胶囊格宽度一致、视觉重心齐平。
    /// 名称与快捷键交给 `.help` 与 `accessibilityLabel`。
    private func iconOnly(symbol: String) -> some View {
        Image(systemName: symbol)
            .fontWeight(.medium)
            .frame(width: Layout.iconSide, height: Layout.iconSide)
    }
}

/// 「更多」展开时与其余工具之间的竖分隔线。
///
/// 只靠留白区分不够——「更多」的成员是真正的绘制工具，和外面的工具语义相同，
/// 用户需要知道「这几格是从那个胶囊里出来的」。
private struct ContainerDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: MarkupToolbarLayout.iconSide - 2)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}
