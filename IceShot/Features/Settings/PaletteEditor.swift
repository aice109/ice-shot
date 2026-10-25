import AppKit
import SwiftUI

/// 设置「标注」页：编辑标注色板（换色 / 增删色 / 恢复默认）。
///
/// 颜色是内容，所以每行用系统 `ColorPicker`（点开是系统颜色面板），不自绘色块 / 弹窗；
/// 2–8 色的约束由 `ColorPalettePreferences` 的三个原子操作保证——视图只负责展示结果，
/// 并把不可能的操作禁用掉（而不是让保存失败后静默吞掉）。
/// 写回后一律从 `UserDefaults` 重新读一遍，保证界面显示的就是真实生效的色板
/// （去重 / 截断等规则已经在数据层做完）。
struct PaletteEditor: View {
    @State private var palette: [EditorColor] = ColorPalettePreferences.palette
    @State private var isConfirmingReset = false

    var body: some View {
        Section("标注") {
            Text("标注颜色用这套色板，新标注默认取第一格。至少 \(ColorPalettePreferences.minimumCount) 色、最多 \(ColorPalettePreferences.maximumCount) 色。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(palette.enumerated()), id: \.element) { index, color in
                colorRow(index: index, color: color)
            }

            HStack(spacing: 12) {
                Button("添加颜色") {
                    addColor()
                }
                .disabled(nextAddColor == nil)
                .help(nextAddColor == nil ? "已经放满，先删掉一格再添加" : "再加一格颜色")

                Button("恢复默认") {
                    isConfirmingReset = true
                }
                .disabled(palette == ColorPalettePreferences.builtInPalette)

                Spacer(minLength: 0)
            }

            if let hint = constraintHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("恢复内置色板？", isPresented: $isConfirmingReset) {
            Button("恢复默认") {
                restoreBuiltIn()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("自定义的色板会被内置 8 色替换，且无法撤销。")
        }
    }

    /// 一行 = 一个颜色：系统颜色面板选色 + 十六进制读数 + 删除。
    private func colorRow(index: Int, color: EditorColor) -> some View {
        HStack(spacing: 10) {
            ColorPicker(
                "第 \(index + 1) 个标注颜色",
                selection: colorBinding(at: index),
                supportsOpacity: false
            )
            .labelsHidden()
            .accessibilityLabel("第 \(index + 1) 个标注颜色")

            Text(color.hexString)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                removeColor(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(palette.count <= ColorPalettePreferences.minimumCount)
            .help(removeHelp)
            .accessibilityLabel("删除第 \(index + 1) 个标注颜色")
        }
    }

    private var removeHelp: String {
        palette.count <= ColorPalettePreferences.minimumCount
            ? "至少保留 \(ColorPalettePreferences.minimumCount) 色"
            : String(localized: "删掉这一格颜色")
    }

    private var constraintHint: String? {
        if palette.count >= ColorPalettePreferences.maximumCount {
            return "已达上限 \(ColorPalettePreferences.maximumCount) 色；要换色请直接点色块修改。"
        }
        if palette.count <= ColorPalettePreferences.minimumCount {
            return "已是最少 \(ColorPalettePreferences.minimumCount) 色，删除按钮已停用。"
        }
        return nil
    }

    private func colorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard palette.indices.contains(index) else {
                    return ColorPalettePreferences.defaultColor.color
                }
                return palette[index].color
            },
            set: { newColor in
                let replacement = EditorColor(nsColor: NSColor(newColor))
                guard let updated = ColorPalettePreferences.replacing(
                    palette,
                    at: index,
                    with: replacement
                ) else {
                    return
                }
                apply(updated)
            }
        )
    }

    /// 添加一格：取一个还没用过的内置色（内置 8 色正好等于上限，所以一定找得到）。
    private var nextAddColor: EditorColor? {
        let palette = palette
        return EditorColor.builtInPalette.first { !palette.contains($0) }
    }

    private func addColor() {
        guard let color = nextAddColor,
              let updated = ColorPalettePreferences.appending(color, to: palette) else {
            return
        }
        apply(updated)
    }

    private func removeColor(at index: Int) {
        guard let updated = ColorPalettePreferences.removing(palette, at: index) else { return }
        apply(updated)
    }

    private func restoreBuiltIn() {
        ColorPalettePreferences.reset()
        palette = ColorPalettePreferences.palette
    }

    /// 落盘后重新读回：显示的就是真正生效的色板。
    private func apply(_ colors: [EditorColor]) {
        guard ColorPalettePreferences.save(colors) else { return }
        palette = ColorPalettePreferences.palette
    }
}
