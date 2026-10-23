import CoreGraphics
import SwiftUI

/// 框选时的像素放大镜：显示光标附近的源像素、网格与当前像素坐标。
///
/// 图像用 `.interpolation(.none)` 保持硬边，放大时看到的是真实像素；
/// 尺寸与位置由 `MagnifierSnapshot` 决定，本视图只负责绘制。
struct MagnifierView: View {
    let image: CGImage
    let snapshot: MagnifierSnapshot

    private var contentSize: CGSize {
        CGSize(
            width: CGFloat(snapshot.columns) * snapshot.cellSize,
            height: CGFloat(snapshot.rows) * snapshot.cellSize
        )
    }

    private var outerSize: CGSize {
        CGSize(width: contentSize.width + 12, height: contentSize.height + 36)
    }

    private var highlightRect: CGRect {
        CGRect(
            x: CGFloat(snapshot.cursorColumn) * snapshot.cellSize,
            y: CGFloat(snapshot.cursorRow) * snapshot.cellSize,
            width: snapshot.cellSize,
            height: snapshot.cellSize
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: contentSize.width, height: contentSize.height)

                PixelGrid(
                    columns: snapshot.columns,
                    rows: snapshot.rows,
                    cellSize: snapshot.cellSize
                )
                .allowsHitTesting(false)

                Path { path in
                    path.addRect(highlightRect)
                }
                .fill(Color.accentColor.opacity(0.18))
                .allowsHitTesting(false)

                Path { path in
                    path.addRect(highlightRect)
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                .allowsHitTesting(false)
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
            }

            Text("\(Int(snapshot.cursorPixel.x)), \(Int(snapshot.cursorPixel.y)) px")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 20)
        }
        .padding(6)
        .frame(width: outerSize.width, height: outerSize.height)
        .glassSurface(
            contrast: .elevated,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityHidden(true)
    }
}

/// 像素网格：每个源像素一格，黑白双描边保证深浅色背景下都看得清。
private struct PixelGrid: View {
    let columns: Int
    let rows: Int
    let cellSize: CGFloat

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for column in 0...columns {
                let x = CGFloat(column) * cellSize
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: CGFloat(rows) * cellSize))
            }
            for row in 0...rows {
                let y = CGFloat(row) * cellSize
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: CGFloat(columns) * cellSize, y: y))
            }
            context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 1)
            context.stroke(path, with: .color(.white.opacity(0.38)), lineWidth: 0.5)
        }
    }
}
