import AppKit
import SwiftUI

/// 编辑器窗口的内容：**与截图浮层同一条玻璃操作条** + 标注画布 + 底部状态栏。
///
/// 撤销走 SwiftUI 环境里的 `UndoManager`，`onAppear` 时交给 `EditorModel`，
/// 这样菜单「撤销 / 重做」和 ⌘Z / ⇧⌘Z 与画布内操作共用同一份撤销栈。
///
/// 操作条**占位不压内容**：编辑是精细活，条浮在图像上会挡视线；
/// 浮层压内容是因为它本来就是「截图上的浮层」，编辑器窗口不需要付这个代价。
struct EditorRootView: View {
    let model: EditorModel
    let actions: MarkupActions
    /// 「贴图」按钮的目标；为 nil 时按钮仍显示但点下去走错误提示。
    var pins: PinBoard?

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            MarkupToolbar(
                model: model,
                context: .editor,
                actions: actions
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            MarkupCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            statusBar
        }
        .background {
            // 窗口背景交给系统材质：26 上它就是液态玻璃的一层，
            // 写死 `windowBackgroundColor` 会把系统玻璃整个盖掉。
            // 低于 26 回退到 `.regularMaterial`，视觉不至于变成空透明。
            Color.clear
                .glassSurface(.regular, in: Rectangle())
                .ignoresSafeArea()
        }
        .onAppear {
            model.attachUndoManager(undoManager)
        }
    }

    /// 编辑器底部状态栏：尺寸、标注数、选中态、当前提示。
    ///
    /// 英文比中文长得多——同一条操作提示中英字符数比约 1:3（中文 34 字、英文 78 字符）。
    /// 全部平铺时最小窗口（640pt）下英文会溢出，所以分两层处理：
    ///
    /// 1. **优先级**：尺寸读数永远保留；标注数与选中态是辅助读数，
    ///    空间不够时先让它们被压缩（`layoutPriority(-1)`）；
    /// 2. **提示可换行**：提示是全行最弹性的内容，允许折到第二行而不是直接截断。
    ///    状态栏本来就靠底，多一行不会遮住画布。
    private var statusBar: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 14) {
                Text("\(model.image.width) × \(model.image.height) px")
                    .monospacedDigit()
                    .lineLimit(1)

                // 标注数是可省的：窄窗口下优先让掉它，而不是把整行挤爆。
                Text("\(model.annotations.count) \(String(localized: "个标注"))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)

                if let selected = model.selectedAnnotation {
                    Text(String(localized: "已选中\(selected.kind.displayName)"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            // 左侧读数不参与拉伸：它们按内容取宽，剩下的空间全给提示。
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            tipText
                // 允许折行（最多两行），再不行才截断。
                // 比一刀切成省略号好读得多，也不会遮住画布——状态栏就在底部。
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tipText: some View {
        if let status = model.statusMessage {
            Text(status)
                .foregroundStyle(.secondary)
        } else if model.isCropping {
            // 尺寸读数由操作条的裁剪胶囊显示，状态栏只留操作提示。
            Text("在图上拖动选择裁剪范围；拖手柄调整；Return 裁剪，Esc 取消")
                .foregroundStyle(.secondary)
        } else {
            Text("拖动绘制；点击标注可选中移动 / ⌫ 删除；⇧ 约束比例")
                .foregroundStyle(.tertiary)
        }
    }
}
