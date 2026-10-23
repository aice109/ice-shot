import AppKit
import SwiftUI

/// 系统材质背景。
///
/// macOS 26 起使用 Liquid Glass；更低版本回退到系统材质（`.regularMaterial`）。
/// 不手绘模糊、不叠加自调透明度——材质始终交给系统。
/// 只有需要响应指针的悬浮控件才使用 `.interactive`。
enum GlassSurfaceKind {
    case regular
    case interactive
}

/// 玻璃的对比档位。
///
/// 系统「液态玻璃」调到最透时，玻璃不再提供底衬，直接压在截图内容上的字形会糊掉。
/// 这类浮层给玻璃加一层**语义染色**（`Glass.tint`）来拿到稳定对比；
/// 染色来自动态语义色（随深浅色、高对比度自动变），不写死颜色、不叠材质、不手绘模糊。
enum GlassContrast {
    /// 常规：玻璃浮在受控背景上（系统窗口 chrome、已压暗的区域）。
    case standard
    /// 抬高：玻璃直接压在任意截图内容上（操作条、HUD、尺寸标签）。
    case elevated

    var tintColor: Color? {
        switch self {
        case .standard:
            return nil
        case .elevated:
            // 浅色外观偏亮、深色外观偏暗，与 label 色同向，字形始终有底。
            // 只取薄薄一层（0.25）：目的是「托底」而不是把玻璃做成磨砂板——
            // 再往上加就明显不像液态玻璃了，剩下的对比交给粗一点的字形与分组形状。
            return Color(nsColor: .windowBackgroundColor).opacity(0.25)
        }
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let kind: GlassSurfaceKind
    let contrast: GlassContrast
    let shape: AnyShape

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass: Glass = kind == .interactive ? .regular.interactive() : .regular
        if let tint = contrast.tintColor {
            glass = glass.tint(tint)
        }
        return glass
    }
}

/// 多个玻璃视图的合并容器：一次渲染多块玻璃，避免逐块开渲染通道。
///
/// 默认 `spacing = 0`（只批处理、不互相粘连），分组之间的留白才是视觉边界；
/// 需要形态互相吸附时才显式给 `spacing`。
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

private struct GlassControlStyleModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// 以系统材质作为背景，`shape` 决定轮廓；`contrast` 决定玻璃是否需要语义染色。
    func glassSurface(
        _ kind: GlassSurfaceKind = .regular,
        contrast: GlassContrast = .standard,
        in shape: some Shape
    ) -> some View {
        modifier(
            GlassSurfaceModifier(kind: kind, contrast: contrast, shape: AnyShape(shape))
        )
    }

    /// 玻璃浮层里的按钮：26+ 用系统液态玻璃按钮，更低版本回退到 `.bordered` 系列。
    ///
    /// `prominent` 用于「当前工具」与主操作——选中态靠强调色玻璃区分，
    /// 而不是靠半透明灰差，最透玻璃下也能一眼看出。
    func glassControlStyle(prominent: Bool = false) -> some View {
        modifier(GlassControlStyleModifier(prominent: prominent))
    }
}
