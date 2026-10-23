import SwiftUI

/// 选区 / 窗口高亮外部的遮罩；用 even-odd 填充在内部挖洞，避免把内容压成纯黑。
struct DimmingOverlay: View {
    /// 需要保持原样的窗口矩形（显示器局部坐标）；空矩形表示整体压暗。
    let selection: CGRect

    var body: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            if selection.width > 0, selection.height > 0 {
                path.addRect(selection)
            }
            context.fill(
                path,
                with: .color(.black.opacity(0.45)),
                style: FillStyle(eoFill: true)
            )
        }
    }
}
