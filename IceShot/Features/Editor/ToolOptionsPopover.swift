import AppKit
import SwiftUI

/// 单个工具的二级选项浮窗：颜色、粗细（各工具共用同一份）、打码样式与块大小。
///
/// 原生 `.popover` 承载（系统玻璃、点击外部关闭、Esc 由系统处理），
/// 不手绘弹窗；控件用系统 `Slider` / `Picker`，颜色是圆形色块按钮
/// （颜色本身就是内容，必须有真实填充；底座 / 阴影一律不自绘）。
struct ToolOptionsPopover: View {
    let model: EditorModel
    let options: EditorToolOptions
    /// 多子型组（形状 / 画笔）的子型行：非空时在顶部先给一排子型图标。
    /// 选中已有标注时为空——选中态只调参数，换子型语义上是「删旧建新」，不做。
    var subOptions: [EditorTool] = []

    /// 色块直径与间距：一行放得下 8 色，彼此不贴着。
    private static let swatchSide: CGFloat = 20
    private static let swatchSpacing: CGFloat = 10
    /// 色块外圈留出的选中环空间。
    private static let swatchInset: CGFloat = 4

    /// 内容宽度：容得下 8 色 × 28 pt + 7 × 10 pt = 294 pt，再多留一点边。
    ///
    /// 之前固定 300 pt 宽、内边距 14 pt，色块行（294 pt）比可用宽度（272 pt）还宽，
    /// 内容会顶穿左右内边距，看起来「贴着玻璃边」而且左边不对齐。
    private static let contentWidth: CGFloat = 308
    /// 四边统一内边距；放在 `frame` 外面，保证玻璃到内容始终有这段距离。
    private static let contentPadding: CGFloat = 16
    /// 不同参数组之间的垂直留白。
    private static let sectionSpacing: CGFloat = 14
    /// 子型按钮的高度：够大才点得中（之前只有文字那一小条）。
    private static let subOptionHeight: CGFloat = 28

    /// 粗细滑块（`Slider` 要 `Double` 区间，模型里存的是 `CGFloat`）。
    private static let widthRange = Double(EditorModel.lineWidthRange.lowerBound)...Double(EditorModel.lineWidthRange.upperBound)

    private var widthBinding: Binding<Double> {
        Binding(
            get: { Double(model.lineWidth) },
            set: { model.setWidth(CGFloat($0)) }
        )
    }

    private var amountBinding: Binding<Double> {
        Binding(
            get: { Double(model.optionsFilterAmount) },
            set: { model.setFilterAmount(CGFloat($0)) }
        )
    }

    private var styleBinding: Binding<RedactionStyle> {
        Binding(
            get: { model.optionsRedactionStyle },
            set: { style in
                model.setRedactionStyle(style)
                model.commitFilterChange()
            }
        )
    }

    private var textBackgroundBinding: Binding<TextBackgroundStyle> {
        Binding(
            get: { model.optionsTextBackground },
            set: { model.setTextBackground($0) }
        )
    }

    private var spotlightShapeBinding: Binding<AreaShape> {
        Binding(
            get: { model.optionsSpotlightShape },
            set: { model.setSpotlightShape($0) }
        )
    }

    private var magnifierShapeBinding: Binding<AreaShape> {
        Binding(
            get: { model.optionsMagnifierShape },
            set: { model.setMagnifierShape($0) }
        )
    }

    private var magnifierZoomBinding: Binding<Double> {
        Binding(
            get: { model.optionsMagnifierZoom },
            set: { model.setMagnifierZoom($0) }
        )
    }

    private var spotlightDimBinding: Binding<Double> {
        Binding(
            get: { model.optionsSpotlightDim },
            set: { model.setSpotlightDim($0) }
        )
    }

    /// 倍数的显示文案：1.5 写成「1.5×」，整数写成「2×」。
    private func zoomLabel(_ zoom: Double) -> String {
        zoom == zoom.rounded() ? "\(Int(zoom))×" : "\(zoom.formatted())×"
    }

    /// 「块大小 / 半径 / 噪点大小」在当前样式下的叫法；纯色样式没有这个参数。
    private var amountTitle: String {
        switch model.optionsRedactionStyle {
        case .mosaic: return "块大小"
        case .blur: return "模糊半径"
        case .noise: return "噪点大小"
        case .solid: return "块大小"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            if !subOptions.isEmpty {
                subOptionSection
                Divider()
            }

            if options.showsColor {
                colorSection
            }

            if let role = options.widthRole {
                sliderSection(
                    title: role.title,
                    value: role.valueLabel(model.lineWidth),
                    binding: widthBinding,
                    range: Self.widthRange,
                    accessibilityLabel: role.title
                ) { isEditing in
                    // 拖动过程中实时预览，松手才进撤销栈（一次拖动＝一步）。
                    if !isEditing {
                        model.commitWidthChange()
                    }
                }
            }

            if options.showsTextBackground {
                Divider()

                Picker("文字背景", selection: textBackgroundBinding) {
                    ForEach(TextBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("文字背景")
            }

            if options.showsSpotlight {
                Divider()

                Picker("亮区形状", selection: spotlightShapeBinding) {
                    ForEach(AreaShape.allCases) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("亮区形状")

                sliderSection(
                    title: "压暗",
                    value: "\(Int((model.optionsSpotlightDim * 100).rounded()))%",
                    binding: spotlightDimBinding,
                    range: SpotlightStyle.dimRange,
                    accessibilityLabel: "压暗程度"
                ) { isEditing in
                    // 拖动中实时预览，松手才进撤销栈。
                    if !isEditing {
                        model.commitSpotlightChange()
                    }
                }
            }

            if options.showsMagnifier {
                Divider()

                Picker("镜框形状", selection: magnifierShapeBinding) {
                    ForEach(AreaShape.allCases) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("镜框形状")

                Picker("放大倍数", selection: magnifierZoomBinding) {
                    ForEach(MagnifierStyle.zoomLevels, id: \.self) { zoom in
                        Text(zoomLabel(zoom)).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("放大倍数")
            }

            if options.showsRedaction {
                Divider()

                Picker("打码样式", selection: styleBinding) {
                    ForEach(RedactionStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("打码样式")

                if model.optionsRedactionStyle.usesAmount {
                    sliderSection(
                        title: amountTitle,
                        value: "\(Int(model.optionsFilterAmount.rounded())) px",
                        binding: amountBinding,
                        range: 4...40,
                        accessibilityLabel: amountTitle
                    ) { isEditing in
                        // 拖动过程中实时预览，松手才进撤销栈。
                        if !isEditing {
                            model.commitFilterChange()
                        }
                    }
                }
            }
        }
        .font(.callout)
        .frame(width: Self.contentWidth, alignment: .leading)
        .padding(Self.contentPadding)
    }

    // MARK: - 参数组

    /// 子型行：一个组按钮里换个画什么。点了就切工具，浮窗留着（还要继续调颜色 / 粗细）。
    ///
    /// 标题按组取（「形状」/「画笔」），不写死成「方式」——否则用户不知道自己正在切什么。
    private var subOptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(subOptions.first?.toolGroup?.subOptionTitle ?? "方式")

            // 等宽等高铺满一行：之前图标 + 文字各自撑宽度，点击区只有文字那么小。
            HStack(spacing: 6) {
                ForEach(subOptions) { tool in
                    subOptionButton(tool)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subOptionButton(_ tool: EditorTool) -> some View {
        let isCurrent = tool == model.tool
        return Button {
            model.setTool(tool)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tool.symbolName)
                    .fontWeight(.medium)
                Text(tool.title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.subOptionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassControlStyle(prominent: isCurrent, clear: true)
        .help(tool.shortcut.map { "\(tool.title)（\(String($0).uppercased())）" } ?? tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var colorSection: some View {
        let swatches = ColorPalettePreferences.displayPalette(current: model.color)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("颜色")

            // 色块行在内容宽度内**居中**：色数变化时两侧留白才对称。
            // 间距按可用宽度收敛（最多 10 pt），色板临时补到 9 色也不会顶出边界。
            HStack(spacing: swatchSpacing(for: swatches.count)) {
                ForEach(swatches, id: \.self) { swatch in
                    swatchButton(swatch)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 带标题与读数的滑块组：标题在左、读数贴右，滑块占满整行。
    private func sliderSection(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        accessibilityLabel: String,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                Spacer(minLength: 12)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: binding, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    /// 组标题比正文低一级，避免和具体参数名抢注意力。
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    /// 色块之间的间距：优先 10 pt，色数多到放不下时按可用宽度收紧。
    private func swatchSpacing(for count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        let cell = Self.swatchSide + Self.swatchInset * 2
        let available = Self.contentWidth - CGFloat(count) * cell
        return max(0, min(Self.swatchSpacing, available / CGFloat(count - 1)))
    }

    /// 圆形色块：填充是颜色本身，选中态用外圈强调色环 + `.isSelected` 无障碍标记。
    private func swatchButton(_ swatch: EditorColor) -> some View {
        let isSelected = swatch == model.color
        let side = Self.swatchSide
        return Button {
            model.setColor(swatch)
        } label: {
            ZStack {
                Circle()
                    .fill(swatch.color)
                    .frame(width: side, height: side)
                    // 白 / 黑在最透玻璃上也要有边界，用语义描边而不是写死颜色。
                    .overlay {
                        Circle().strokeBorder(.separator, lineWidth: 0.5)
                    }

                if isSelected {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: side + Self.swatchInset * 2, height: side + Self.swatchInset * 2)
                }
            }
            .frame(width: side + Self.swatchInset * 2, height: side + Self.swatchInset * 2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(swatch.hexString)
        .accessibilityLabel("标注颜色 \(swatch.hexString)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
