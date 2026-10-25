import AppKit
import SwiftUI

/// 系统材质背景。
///
/// macOS 26 起使用 Liquid Glass；更低版本回退到系统材质（`.regularMaterial`）。
/// 不手绘模糊、不叠加自调透明度——材质始终交给系统。
///
/// **效果强度交给系统设置。** 26 起系统提供「玻璃强度 / 减少透明度」偏好，
/// 本应用不自行做可读性补偿（染色、加粗字形、二次底衬），
/// 让最透档位真的透——怎么调由用户在系统设置里决定。
/// 唯一的例外是 `GlassContrast.boosted`，留作实测后的逃生口，默认不用。
enum GlassSurfaceKind {
    /// 标准玻璃：系统自己按上下文调透明度。窗口 chrome、列表、表单等受控背景用它。
    case regular
    /// 最透玻璃：几乎不提供底衬，压在截图内容上液态感最强。浮层与操作条用它。
    case clear
    /// 标准玻璃 + 指针响应：可悬停、可按下的悬浮控件。
    case interactive

    @available(macOS 26.0, *)
    fileprivate func baseGlass() -> Glass {
        switch self {
        case .regular:
            return .regular
        case .clear:
            return .clear
        case .interactive:
            return .regular.interactive()
        }
    }
}

/// 玻璃的染色档位。
///
/// 默认 `.none`：裸玻璃，不加语义染色。系统最透档位下字形会变淡，
/// 这是用户选择的结果，应用不替他做决定。
///
/// `.boosted` 是实测后的逃生口：给玻璃加一层薄语义染色托底，
/// 用于真机上确认某个浮层透到不可用的场合。**默认不启用。**
enum GlassContrast {
    /// 不染色（默认）：完全交给系统强度设置。
    case none
    /// 与 `.none` 等价。保留该名字只为既有调用点可读，语义上「标准背景」不需要染色。
    case standard
    /// 加薄语义染色托底：`.windowBackgroundColor` 的 0.25。
    case boosted

    var usesTint: Bool {
        self == .boosted
    }

    /// 染色颜色。只有 `.boosted` 给值。
    ///
    /// 浅色外观偏亮、深色外观偏暗，与 label 色同向。用动态语义色，
    /// 随深浅色与高对比度自动变，**不写死 RGB**。
    var tintColor: Color? {
        guard usesTint else { return nil }
        return Color(nsColor: .windowBackgroundColor).opacity(0.25)
    }

    /// 把染色档位应用到玻璃上（26+）。
    @available(macOS 26.0, *)
    func apply(to glass: Glass) -> Glass {
        guard let tint = tintColor else { return glass }
        return glass.tint(tint)
    }
}

// MARK: - 玻璃渲染

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
        contrast.apply(to: kind.baseGlass())
    }
}

/// 多个玻璃视图的合并容器：一次渲染多块玻璃，避免逐块开渲染通道。
///
/// `spacing` 控制**吸附距离**：间距小于它的玻璃会真实融合成一体。
/// 默认 `0` 只批处理不粘连；需要形态互相吸附时显式给值。
///
/// 26 起配合 `glassEffectID(_:in:)` 可以做形状变形（morph）——
/// 组内视图增删时玻璃从旧形状流成新形状，而不是硬切。
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
    let clear: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            styled(content)
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }

    /// 26+ 的液态玻璃按钮。`clear` 只切换玻璃的透度，轮廓仍交给系统——
    /// 玻璃按钮自带与硬件曲率同向的圆角，自己套一层 capsule 会破坏同心。
    @available(macOS 26.0, *)
    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

// MARK: - 形状变形

extension View {
    /// 玻璃形状变形：同一 `namespace` 下 id 相同的玻璃在增删时互相流动。
    ///
    /// 低于 26 时无效果——低版本的材质本来就没有 morph 能力，
    /// 退化成一个无操作的透传，调用点不必写版本分支。
    @ViewBuilder
    func glassMorphID(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

// MARK: - 对外接口

extension View {
    /// 以系统材质作为背景，`shape` 决定轮廓；`contrast` 决定是否额外染色（默认不染）。
    func glassSurface(
        _ kind: GlassSurfaceKind = .regular,
        contrast: GlassContrast = .none,
        in shape: some Shape
    ) -> some View {
        modifier(
            GlassSurfaceModifier(kind: kind, contrast: contrast, shape: AnyShape(shape))
        )
    }

    /// 玻璃浮层里的按钮：26+ 用系统液态玻璃按钮，更低版本回退到 `.bordered` 系列。
    ///
    /// `prominent` 用于「当前工具」与主操作；`clear` 换到最透档位，
    /// 让选中格子在液态玻璃下保持通透，而不是压成一块强调色板。
    func glassControlStyle(prominent: Bool = false, clear: Bool = false) -> some View {
        modifier(GlassControlStyleModifier(prominent: prominent, clear: clear))
    }
}
