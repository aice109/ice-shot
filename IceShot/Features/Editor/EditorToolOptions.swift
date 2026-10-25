import Foundation

/// 工具 → 二级选项的纯逻辑映射：弹出层显示哪些控件，以及「线宽」在这件工具上的真实含义。
///
/// 全项目只有**一份** `EditorModel.lineWidth`，各工具按自己的规则换算成实际像素：
/// 线宽本身、高亮笔迹、文字字号、序号徽章直径、打码笔刷。换算集中在这里，
/// 绘制（`EditorModel.activeStyle`）与弹出层显示（`ToolOptionsPopover`）共用，
/// 避免「滑块显示 8 px、画出来却是 24 px」这种不一致。
struct EditorToolOptions: Equatable {
    /// 线宽在这件工具上的含义。
    enum WidthRole: Equatable, CaseIterable {
        /// 线宽本身（矩形、椭圆、直线、箭头、画笔）。
        case line
        /// 高亮笔迹粗细（线宽 × 3，最小 12）。
        case highlighter
        /// 文字字号（线宽 × 6，最小 16）。
        case fontSize
        /// 序号徽章直径（线宽 × 6，最小 20）。
        case badge
        /// 打码笔刷直径（线宽 × 4，最小 12）。
        case brush

        /// 滑块标题：让用户知道这一格调的是「这件工具上的什么」。
        var title: String {
            switch self {
            case .line: return String(localized: "粗细")
            case .highlighter: return String(localized: "高亮粗细")
            case .fontSize: return String(localized: "字号")
            case .badge: return String(localized: "徽章大小")
            case .brush: return String(localized: "笔刷粗细")
            }
        }

        /// 同一个 `lineWidth` 换算成这件工具的实际像素值。
        func resolved(_ lineWidth: CGFloat) -> CGFloat {
            switch self {
            case .line: return max(1, lineWidth)
            case .highlighter: return max(12, lineWidth * 3)
            case .fontSize: return max(16, lineWidth * 6)
            case .badge: return max(20, lineWidth * 6)
            case .brush: return max(12, lineWidth * 4)
            }
        }

        /// 弹出层右侧的读数（换算后的真实值，不是滑块原始值）。
        func valueLabel(_ lineWidth: CGFloat) -> String {
            "\(Int(resolved(lineWidth).rounded())) px"
        }
    }

    /// 是否显示颜色色井。
    let showsColor: Bool
    /// 粗细滑块的语义；`nil` 表示这件工具没有粗细参数。
    let widthRole: WidthRole?
    /// 是否显示打码样式与块大小 / 半径。
    let showsRedaction: Bool
    /// 是否显示文字背景（无 / 实底 / 半透）。
    let showsTextBackground: Bool
    /// 是否显示聚光灯的形状与暗度。
    let showsSpotlight: Bool
    /// 是否显示放大镜的形状与倍数。
    let showsMagnifier: Bool

    /// 有没有需要弹出的选项；`false` 的工具（选择 / 裁剪）点了不弹窗。
    var isPresented: Bool {
        showsColor || widthRole != nil || showsRedaction
            || showsTextBackground || showsSpotlight || showsMagnifier
    }

    /// 打码标注被选中时弹的那份选项：只留这一类自己的参数。
    ///
    /// 选中态不重复给颜色 / 粗细——它们在画布上是「以后新标注用什么」，
    /// 而选中一条已有标注时最想改的是它的样式与强度，两套语义混一个浮窗会互相打架。
    static let selectedRedaction = EditorToolOptions(
        showsColor: false,
        widthRole: nil,
        showsRedaction: true
    )

    /// 文字标注被选中时的选项：只留背景样式。
    static let selectedText = EditorToolOptions(
        showsColor: false,
        widthRole: nil,
        showsTextBackground: true
    )

    /// 聚光灯标注被选中时的选项（与聚光灯工具那份内容相同，本来就只有形状与暗度）。
    static let spotlight = EditorToolOptions(
        showsColor: false,
        widthRole: nil,
        showsSpotlight: true
    )

    /// 形状 / 画笔族标注被选中时的选项：**只给粗细，不给颜色**。
    ///
    /// 颜色与粗细在工具格那边是一对「以后新标注用什么」的默认值；
    /// 而选中一条已有标注时最想改的是它的实际样式。只给粗细既补齐了真实缺口，
    /// 又与 `selectedText`（只给背景）的风格对齐，不会多出一个与工具格完全重复的入口。
    static let selectedStroke = EditorToolOptions(
        showsColor: false,
        widthRole: .line
    )

    /// 放大镜标注被选中时的选项（同上）。
    static let magnifier = EditorToolOptions(
        showsColor: false,
        widthRole: nil,
        showsMagnifier: true
    )

    /// 选中已有标注时该弹的选项；`nil` 表示这种标注没有专属参数。
    ///
    /// 全项目只有这一处「类型 → 选中态选项」的映射，不用给每种类型各开一个后门按钮。
    static func forKind(_ kind: AnnotationKind) -> EditorToolOptions? {
        switch kind {
        case .text: return .selectedText
        case .pixelate, .blur: return .selectedRedaction
        case .spotlight: return .spotlight
        case .magnifier: return .magnifier
        case .rectangle, .ellipse, .line, .arrow, .freehand, .highlighter:
            return .selectedStroke
        case .number:
            return nil
        }
    }

    /// 线宽可在这条标注上直接调的标注类型。
    ///
    /// 形状与画笔族收进组合按钮后，「选中后调粗细」成为自然的事，
    /// 顺便补齐了以前「选中矩形只能拖、不能调粗细」的缺口。
    static func isStrokeAdjustable(_ kind: AnnotationKind) -> Bool {
        switch kind {
        case .rectangle, .ellipse, .line, .arrow, .freehand, .highlighter: return true
        case .text, .number, .pixelate, .blur, .spotlight, .magnifier: return false
        }
    }

    init(
        showsColor: Bool,
        widthRole: WidthRole?,
        showsRedaction: Bool = false,
        showsTextBackground: Bool = false,
        showsSpotlight: Bool = false,
        showsMagnifier: Bool = false
    ) {
        self.showsColor = showsColor
        self.widthRole = widthRole
        self.showsRedaction = showsRedaction
        self.showsTextBackground = showsTextBackground
        self.showsSpotlight = showsSpotlight
        self.showsMagnifier = showsMagnifier
    }

    init(tool: EditorTool) {
        switch tool {
        case .select, .crop:
            self.init(showsColor: false, widthRole: nil)
        case .rectangle, .ellipse, .line, .arrow, .freehand:
            self.init(showsColor: true, widthRole: .line)
        case .highlighter:
            self.init(showsColor: true, widthRole: .highlighter)
        case .text:
            self.init(showsColor: true, widthRole: .fontSize, showsTextBackground: true)
        case .number:
            self.init(showsColor: true, widthRole: .badge)
        case .pixelate:
            self.init(showsColor: true, widthRole: .brush, showsRedaction: true)
        case .spotlight:
            self.init(showsColor: false, widthRole: nil, showsSpotlight: true)
        case .magnifier:
            self.init(showsColor: false, widthRole: nil, showsMagnifier: true)
        }
    }
}
