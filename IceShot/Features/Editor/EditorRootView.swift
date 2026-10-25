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

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(model.image.width) × \(model.image.height) px")
                .monospacedDigit()
            Text("\(model.annotations.count) 个标注")
                .foregroundStyle(.secondary)

            if let selected = model.selectedAnnotation {
                Text("已选中\(selected.kind.displayName)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

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
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
