import AppKit
import SwiftUI

/// 「带壳」popover：开关 + 实时预览。
///
/// 预览和最终导出共用 `ScreenshotFrameComposer`，只是这里传 `maximumDimension` 做降采样。
/// 第一版主画布不改成带壳显示：浮层里的选区、边框、手柄都绑定原图坐标，
/// 把壳画到选区外会和现有交互打架。
struct ScreenshotFramePopover: View {
    let model: EditorModel
    /// 内容图（已渲染标注、浮层里还要先按选区裁剪）。为 nil 时无法生成预览。
    let content: (() -> CGImage?)?

    @State private var preview: CGImage?
    @State private var isRendering = true

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.isFrameEnabled },
            set: { model.setFrameEnabled($0) }
        )
    }

    private var statusText: String {
        guard model.isFrameEnabled else { return String(localized: "未启用") }
        return model.frameStyle?.chrome.title ?? String(localized: "窗口")
    }

    private var hintText: String {
        model.isFrameEnabled
            ? String(localized: "已开启：复制 / 保存 / 贴图会带上这层壳；历史记录仍存原图。")
            : String(localized: "开启后按上次的样式生成预览。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("带壳", isOn: enabled)
                    .toggleStyle(.switch)

                Spacer(minLength: 12)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            previewArea

            Text(hintText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
        .task(id: model.frameStyle) {
            renderPreview()
        }
    }

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
        .frame(height: 220)
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
