import AppKit
import SwiftUI

/// 「带壳」popover：开关 + 样式选项 + 实时预览。
///
/// 预览和最终导出共用 `ScreenshotFrameComposer`，只是这里传 `maximumDimension` 做降采样。
/// 主画布不改成带壳显示：浮层里的选区、边框、手柄都绑定原图坐标，
/// 把壳画到选区外会和现有交互打架。
///
/// 控件沿用 `ToolOptionsPopover` 的语言：系统 `Picker`(.segmented) / `Toggle` / `TextField`，
/// 不手绘弹窗，材质交给系统。
struct ScreenshotFramePopover: View {
    let model: EditorModel
    /// 内容图（已渲染标注、浮层里还要先按选区裁剪）。为 nil 时无法生成预览。
    let content: (() -> CGImage?)?

    @State private var preview: CGImage?
    @State private var isRendering = true

    /// popover 宽度。
    ///
    /// 按**英文**文案算：五档背景（Transparent / Graphite / Ocean / Sunrise / Aurora）
    /// 全屏时约 321 pt，360 宽的可用区只有 328 pt，只剩 7 pt 余量——
    /// 系统字号或字重稍有变化就会被截断。留到 420，让两种语言都排得下。
    private static let contentWidth: CGFloat = 420
    /// 预览区高度。
    private static let previewHeight: CGFloat = 200
    /// 分组之间的留白。
    private static let sectionSpacing: CGFloat = 12

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.isFrameEnabled },
            set: { model.setFrameEnabled($0) }
        )
    }

    /// 当前样式；未开启时用默认值兜底，好让控件始终有值可显示。
    private var style: ScreenshotFrameStyle {
        model.frameStyle ?? model.defaultFrameStyle
    }

    private var hintText: String {
        model.isFrameEnabled
            ? String(localized: "已开启：复制 / 保存 / 贴图会带上这层壳；历史记录仍存原图。")
            : String(localized: "开启后按上次的样式生成预览。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header

            previewArea

            if model.isFrameEnabled {
                Divider()
                styleControls
            }

            Text(hintText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: Self.contentWidth)
        .task(id: model.frameStyle) {
            renderPreview()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Toggle("带壳", isOn: enabled)
                .toggleStyle(.switch)

            Spacer(minLength: 12)

            Text(model.isFrameEnabled ? style.chrome.title : String(localized: "未启用"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 预览

    private var previewArea: some View {
        ZStack {
            CheckerboardBackground()

            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
            } else if isRendering {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("无法生成预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.isFrameEnabled
                ? String(localized: "带壳预览")
                : String(localized: "原图预览")
        )
    }

    // MARK: - 样式控件

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            chromeSection

            labeledPicker(String(localized: "外观"), selection: appearanceBinding) {
                ForEach(ScreenshotFrameStyle.Appearance.allCases, id: \.self) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }

            labeledPicker(String(localized: "背景"), selection: backgroundBinding) {
                ForEach(ScreenshotFrameStyle.Background.allCases, id: \.self) { background in
                    Text(background.title).tag(background)
                }
            }

            labeledPicker(String(localized: "边距"), selection: paddingBinding) {
                ForEach(ScreenshotFrameStyle.Padding.allCases, id: \.self) { padding in
                    Text(padding.title).tag(padding)
                }
            }

            HStack(spacing: 10) {
                Text("阴影")
                Spacer(minLength: 12)
                Toggle("阴影", isOn: shadowBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("阴影")
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("标题")
                    .font(.callout)
                // 默认空：不自动填窗口标题，避免把窗口标题里的隐私带进导出图。
                TextField("可选，默认不显示", text: titleBinding)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("标题")
            }
        }
        .font(.callout)
    }

    /// 一行「标签 + 分段控件」。标签固定宽度，让四组分段控件左边对齐。
    private func labeledPicker<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
            Picker(title, selection: selection, content: content)
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    /// 壳形态。窗口截图只有一档：不画选择器，直接说明为什么。
    @ViewBuilder
    private var chromeSection: some View {
        let options = model.allowedChrome
        if options.count > 1 {
            labeledPicker(String(localized: "样式"), selection: chromeBinding) {
                ForEach(options, id: \.self) { chrome in
                    Text(chrome.title).tag(chrome)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("样式")
                    .font(.callout)
                Text(options.first?.title ?? ScreenshotFrameStyle.Chrome.shadowOnly.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("这张图本身已是窗口截图，自带红黄绿，只提供「仅阴影」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 绑定（全部写回 `EditorModel.setFrameStyle`）

    private var chromeBinding: Binding<ScreenshotFrameStyle.Chrome> {
        Binding(
            get: { style.chrome },
            set: { value in updateStyle { $0.chrome = value } }
        )
    }

    private var appearanceBinding: Binding<ScreenshotFrameStyle.Appearance> {
        Binding(
            get: { style.appearance },
            set: { value in updateStyle { $0.appearance = value } }
        )
    }

    private var backgroundBinding: Binding<ScreenshotFrameStyle.Background> {
        Binding(
            get: { style.background },
            set: { value in updateStyle { $0.background = value } }
        )
    }

    private var paddingBinding: Binding<ScreenshotFrameStyle.Padding> {
        Binding(
            get: { style.padding },
            set: { value in updateStyle { $0.padding = value } }
        )
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { style.showsShadow },
            set: { value in updateStyle { $0.showsShadow = value } }
        )
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { style.title },
            set: { value in updateStyle { $0.title = value } }
        )
    }

    /// 改一项就整组写回：`task(id: model.frameStyle)` 因此会重绘预览。
    private func updateStyle(_ mutate: (inout ScreenshotFrameStyle) -> Void) {
        var updated = style
        mutate(&updated)
        model.setFrameStyle(updated)
    }

    // MARK: - 渲染

    private func renderPreview() {
        isRendering = true
        defer { isRendering = false }

        guard let contentImage = content?() else {
            preview = nil
            return
        }

        if let style = model.frameStyle {
            preview = try? ScreenshotFrameComposer.render(
                contentImage,
                style: style,
                maximumDimension: 720
            )
        } else {
            preview = contentImage
        }
    }
}

/// 透明底的棋盘格。它是「透明」的视觉说明，不是界面材质。
private struct CheckerboardBackground: View {
    private let cell: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            let colors = [
                Color(nsColor: .controlBackgroundColor),
                Color(nsColor: .windowBackgroundColor),
            ]

            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(
                        Path(rect),
                        with: .color(colors[(row + column) % 2])
                    )
                }
            }
        }
    }
}
