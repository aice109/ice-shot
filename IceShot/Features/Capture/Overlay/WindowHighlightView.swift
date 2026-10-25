import SwiftUI

/// 窗口高亮的统一画法：描边 + 窗口名胶囊。
///
/// 窗口选择模式与合并后的框选浮层共用，保证两处高亮的线宽、胶囊与避让规则一致。
struct WindowHighlight: View {
    /// 窗口在显示器局部坐标中的可见矩形。
    let rect: CGRect
    let name: String
    /// 所在显示器的大小（points），用于把胶囊收进屏内。
    let bounds: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(rect)
            }
            .stroke(Color.accentColor, lineWidth: 2)

            WindowNameLabel(name: name)
                .frame(maxWidth: 360, alignment: .leading)
                .offset(x: labelX, y: labelY)
        }
        .allowsHitTesting(false)
    }

    private var labelX: CGFloat {
        let maxX = max(8, bounds.width - 368)
        return min(max(rect.minX + 8, 8), maxX)
    }

    private var labelY: CGFloat {
        if rect.minY >= 36 {
            return max(8, rect.minY - 34)
        }
        return min(bounds.height - 36, rect.minY + 8)
    }
}

/// 窗口名：玻璃胶囊，单行截断。
struct WindowNameLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassSurface(.clear, contrast: .none, in: Capsule())
    }
}
