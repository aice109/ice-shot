import AppKit
import CoreGraphics
import SwiftUI

/// 模型层颜色使用 sRGB 分量，避免直接存 SwiftUI `Color`，便于后续 Codable / 导出。
///
/// 纯值类型、不碰 UI，显式 `nonisolated`：默认 `@MainActor` 隔离下，
/// 内置色板这类常量才不会被当作主线程状态（`ColorPalettePreferences` 同样处理）。
nonisolated struct EditorColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let defaultRed = EditorColor(red: 1, green: 0.22, blue: 0.18, alpha: 1)

    /// 内置标注色板（默认值）：红 / 橙 / 黄 / 绿 / 蓝 / 紫 / 黑 / 白。
    ///
    /// 用户可在设置里改成自己的色板（存 `UserDefaults`，见 `ColorPalettePreferences`），
    /// 这里只是「没改过」时的默认。
    static let builtInPalette: [EditorColor] = builtInPaletteHex.compactMap(EditorColor.init(hex:))

    private static let builtInPaletteHex = [
        "#FF382E", // 红
        "#FF9400", // 橙
        "#FFCC00", // 黄
        "#33C759", // 绿
        "#007AFF", // 蓝
        "#9461EB", // 紫
        "#000000", // 黑
        "#FFFFFF", // 白
    ]

    /// `#RRGGBB` 或 `#RRGGBBAA`（`#` 可省，大小写不限）；解析失败返回 `nil`。
    init?(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        digits = digits.uppercased()
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit }),
              let value = UInt64(digits, radix: 16) else {
            return nil
        }
        let hasAlpha = digits.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// 存盘用的 `#RRGGBB`（各分量按 8 bit 取整，alpha 为 1 时省略）。
    var hexString: String {
        func component(_ value: Double) -> UInt64 {
            UInt64((min(max(value, 0), 1) * 255).rounded())
        }
        let red = component(red)
        let green = component(green)
        let blue = component(blue)
        let base = String(format: "#%02X%02X%02X", red, green, blue)
        guard alpha < 1 else { return base }
        return base + String(format: "%02X", component(alpha))
    }

    /// 与这个颜色搭配的可读文字色：亮底用黑、暗底用白。
    ///
    /// 用相对亮度（sRGB 线性化后的加权和）判定，而不是看白 / 黑哪个更「直观」——
    /// 文字背景的自动取色靠它，画布与导出走同一套判断。
    var readableTextColor: EditorColor {
        func linear(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.03928 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > 0.45 ? .readableDark : .readableLight
    }

    /// 可读性用的纯黑 / 纯白。
    static let readableDark = EditorColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let readableLight = EditorColor(red: 1, green: 1, blue: 1, alpha: 1)

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(nsColor: NSColor) {
        guard let converted = nsColor.usingColorSpace(.sRGB) else {
            self = .defaultRed
            return
        }
        self.red = Double(converted.redComponent)
        self.green = Double(converted.greenComponent)
        self.blue = Double(converted.blueComponent)
        self.alpha = Double(converted.alphaComponent)
    }
}

enum EditorTool: String, CaseIterable, Identifiable {
    /// 「无工具」态：**在操作条上占第一格**，默认就处于这个态。
    ///
    /// 选它等于「当前不画任何东西」，画布照旧可以点选 / 拖动已有标注。
    /// 它是用户看得见、点得到的显式退出路径——以前只能靠再点一次已激活的工具
    /// 或按 `V` 退出，两条路都没有可见入口。
    case select
    /// 裁剪不是标注工具：它在画布上操作图像本身的矩形范围（见 `EditorModel.cropRect`）。
    case crop
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlighter
    case text
    /// 序号徽章：单击放置、自动递增的数字标记。
    case number
    case pixelate
    /// 聚光灯：选区之外压暗，把注意力收紧到一块区域（可多条叠加）。
    case spotlight
    /// 放大镜：框住一块区域，框内显示这块区域自身的放大内容。
    case magnifier

    /// 多子型组：一个按钮承载多个工具，按钮图标显示「上次用的那个子型」。
    ///
    /// 组内成员顺序即浮窗里子型行的顺序，也决定键位与测试的期望。
    enum ToolGroup: String, CaseIterable, Sendable {
        /// 形状：矩形 / 椭圆 / 直线，三者在二级选项浮窗里切换。
        case shape
        /// 画笔：画笔 / 荧光笔，两者在二级选项浮窗里切换。
        case brush
        /// 更多：序号 / 聚光灯 / 放大镜，点开后就地横向展开三个格子。
        case more

        /// 组内成员（顺序即浮窗与展开后的展示顺序）。
        var members: [EditorTool] {
            switch self {
            case .shape: return [.rectangle, .ellipse, .line]
            case .brush: return [.freehand, .highlighter]
            case .more: return [.number, .spotlight, .magnifier]
            }
        }

        /// 浮窗里子型行的标题：告诉用户正在切的是哪一组，不写成笼统的「方式」。
        var subOptionTitle: String {
            switch self {
            case .shape: return String(localized: "形状")
            case .brush: return String(localized: "画笔")
            case .more: return String(localized: "更多")
            }
        }
    }

    /// 这个工具属于哪个多子型组；`nil` 表示自己独占一格。
    var toolGroup: ToolGroup? {
        ToolGroup.allCases.first { $0.members.contains(self) }
    }

    /// 某一组的工具，顺序与 `allCases` 一致（快捷键、验收都用这个顺序）。
    static func tools(in group: ToolGroup) -> [EditorTool] {
        group.members
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return String(localized: "选择")
        case .crop: return String(localized: "裁剪")
        case .rectangle: return String(localized: "矩形")
        case .ellipse: return String(localized: "椭圆")
        case .line: return String(localized: "直线")
        case .arrow: return String(localized: "箭头")
        case .freehand: return String(localized: "画笔")
        case .highlighter: return String(localized: "高亮")
        case .text: return String(localized: "文字")
        case .number: return String(localized: "序号")
        case .pixelate: return String(localized: "马赛克")
        case .spotlight: return String(localized: "聚光灯")
        case .magnifier: return String(localized: "放大镜")
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow.rays"
        case .crop: return "crop"
        case .rectangle: return "rectangle"
        // 形状工具画的是可任意压扁的椭圆，`oval` 比正圆的 `circle` 更准确。
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .freehand: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .number: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        case .spotlight: return "light.beacon.max"
        case .magnifier: return "plus.magnifyingglass"
        }
    }

    var shortcut: Character? {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .freehand: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .number: return "n"
        case .pixelate: return "m"
        case .spotlight: return "s"
        case .magnifier: return "z"
        }
    }

    var annotationKind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .freehand: return .freehand
        case .highlighter: return .highlighter
        case .text: return .text
        case .number: return .number
        case .pixelate: return .pixelate
        case .spotlight: return .spotlight
        case .magnifier: return .magnifier
        }
    }

}

/// 打码样式：用户可见的「马赛克质感」，不只是块形状。
///
/// - `mosaic`：方块像素化 + 细网格，纯色区域也能看出已被打码；
/// - `blur`：高斯模糊；
/// - `noise`：雪花噪点（完全替代内容）；
/// - `solid`：纯色遮挡（使用标注颜色）。
enum RedactionStyle: String, CaseIterable, Identifiable, Sendable {
    case mosaic
    case blur
    case noise
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mosaic: return String(localized: "马赛克")
        case .blur: return String(localized: "模糊")
        case .noise: return String(localized: "噪点")
        case .solid: return String(localized: "纯色")
        }
    }

    var symbolName: String {
        switch self {
        case .mosaic: return "checkerboard.rectangle"
        case .blur: return "camera.filters"
        case .noise: return "snowflake"
        case .solid: return "rectangle.fill"
        }
    }

    /// 是否使用「块大小 / 半径」参数。
    var usesAmount: Bool {
        self != .solid
    }
}

enum AnnotationKind: String, Sendable {
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlighter
    case text
    case number
    case pixelate
    case blur
    /// 聚光灯：区域外压暗。
    case spotlight
    /// 放大镜：框内显示该区域自身的放大内容。
    case magnifier

    var displayName: String {
        switch self {
        case .rectangle: return String(localized: "矩形")
        case .ellipse: return String(localized: "椭圆")
        case .line: return String(localized: "直线")
        case .arrow: return String(localized: "箭头")
        case .freehand: return String(localized: "画笔")
        case .highlighter: return String(localized: "高亮")
        case .text: return String(localized: "文字")
        case .number: return String(localized: "序号")
        case .pixelate: return String(localized: "马赛克")
        case .blur: return String(localized: "模糊")
        case .spotlight: return String(localized: "聚光灯")
        case .magnifier: return String(localized: "放大镜")
        }
    }

    /// 需要背景像素（原图）参与绘制，不能只靠几何路径。
    var needsSourceImage: Bool {
        self == .pixelate || self == .blur
    }

    /// 用「笔迹路径」表达：自由画笔、高亮、以及涂抹式马赛克 / 模糊。
    var usesStrokePath: Bool {
        self == .freehand || self == .highlighter || self == .pixelate || self == .blur
    }
}

/// 文字背景：文字压在花哨截图上时的可读性处理。
///
/// - `solid`：底色就把标注色拉满，文字取自动对比色；
/// - `translucent`：同上但底色只到 60%，保留一点图的质感（文字仍取自动对比色，
///   否则白字压白底会直接看不见）。
///
/// 只在文字标注上有意义；其它标注类型忽略这个字段。
enum TextBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case none
    case solid
    case translucent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "无")
        case .solid: return String(localized: "实底")
        case .translucent: return String(localized: "半透")
        }
    }

    /// 底色不透明度；`none` 不画背景。
    var fillOpacity: Double {
        switch self {
        case .none: return 0
        case .solid: return 1
        case .translucent: return 0.6
        }
    }

    var drawsBackground: Bool { self != .none }
}

/// 聚光灯：只保留一块区域亮着，其余部分按暗度压暗。
///
/// - `dim`：压暗力度（0.3–0.9）；多条叠加时暗度会累加，这是有意为之——
///   两圈重点区域叠在一起，重叠部分更暗。
/// - `shape`：亮着的区域是椭圆还是矩形。
///
/// 聚光灯与放大镜共用这一份形状选择，避免两处各写一套同义枚举。
enum AreaShape: String, CaseIterable, Identifiable, Sendable {
    case ellipse
    case rectangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ellipse: return String(localized: "椭圆")
        case .rectangle: return String(localized: "矩形")
        }
    }
}

struct SpotlightStyle: Equatable, Sendable {
    var shape: AreaShape = .ellipse
    var dim: Double = SpotlightStyle.defaultDim

    static let defaultDim: Double = 0.6
    static let dimRange: ClosedRange<Double> = 0.3...0.9

    /// 夹到合法区间的暗度；读与写都过这里，避免存进不可见的极值。
    var clampedDim: Double {
        min(max(dim, Self.dimRange.lowerBound), Self.dimRange.upperBound)
    }
}

/// 放大镜：框内显示这块区域自身的放大内容（所见即所得，不从别处采样）。
///
/// 实现就是把原图按 `zoom` 放大、以框中心为锚点重新摆好，再裁到框内——
/// 因此框里看到的是「中心那一小块被放大」，边缘会被裁掉，这是放大镜的固有行为。
struct MagnifierStyle: Equatable, Sendable {
    var shape: AreaShape = .ellipse
    var zoom: Double = MagnifierStyle.defaultZoom

    static let defaultZoom: Double = 2
    /// 可选倍数：只有三档，够用且不用滑块。
    static let zoomLevels: [Double] = [1.5, 2, 3]

    /// 夹到可选范围内（读与写都过这里）。
    var clampedZoom: Double {
        min(max(zoom, Self.zoomLevels.first ?? 1.5), Self.zoomLevels.last ?? 3)
    }
}

struct AnnotationStyle: Equatable, Sendable {
    var color: EditorColor
    var lineWidth: CGFloat
    var opacity: Double
    /// 仅文字标注使用；按原图像素定义，导出与显示一致。
    var fontSize: CGFloat? = nil
    /// 仅马赛克 / 模糊使用：块大小 / 模糊半径，按原图像素定义（4–40）。
    /// 与 `lineWidth` 分开存，避免「块大小」被线宽滑块间接控制。
    var filterAmount: CGFloat? = nil
    /// 仅打码（马赛克 / 模糊）使用：质感样式。
    var redactionStyle: RedactionStyle? = nil
    /// 仅文字使用：背景底色。
    var textBackground: TextBackgroundStyle? = nil
    /// 仅聚光灯使用：形状与暗度。
    var spotlight: SpotlightStyle? = nil
    /// 仅放大镜使用：形状与倍数。
    var magnifier: MagnifierStyle? = nil
}

/// 坐标统一为原图像素坐标（左上原点）；视图层只负责映射。
struct EditorAnnotation: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    /// 仅文字标注使用。
    var text: String?
    /// 仅序号标注使用：徽章里显示的数字（自动递增，见 `EditorModel.nextNumber`）。
    var number: Int?
    var style: AnnotationStyle

    init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        start: CGPoint,
        end: CGPoint,
        points: [CGPoint] = [],
        text: String? = nil,
        number: Int? = nil,
        style: AnnotationStyle
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.points = points
        self.text = text
        self.number = number
        self.style = style
    }

    /// 文字标注的字号，默认随线宽缩放（与工具栏同一个滑块）。
    var textFontSize: CGFloat {
        style.fontSize ?? 24
    }

    /// 文字背景样式（未设置即无背景）。
    var textBackground: TextBackgroundStyle {
        style.textBackground ?? .none
    }

    /// 聚光灯参数；非聚光灯标注返回默认值（绘制时用不到）。
    var spotlightStyle: SpotlightStyle {
        style.spotlight ?? SpotlightStyle()
    }

    /// 放大镜参数；非放大镜标注返回默认值（绘制时用不到）。
    var magnifierStyle: MagnifierStyle {
        style.magnifier ?? MagnifierStyle()
    }

    /// 需要原图像素参与绘制、但不是走 `MarkupFilters` 的局部滤镜。
    var samplesSourceImage: Bool {
        kind == .magnifier
    }


    /// 文字背景的内边距：按字号派生，字号调大时背景块跟着变舒。
    var textBackgroundPadding: CGFloat {
        guard textBackground.drawsBackground else { return 0 }
        return (textFontSize * 0.35).rounded()
    }

    /// 文字背景的圆角。
    var textBackgroundCornerRadius: CGFloat {
        (textFontSize * 0.25).rounded()
    }

    /// 文字整体占位框：字形尺寸 + 背景内边距（无背景时就是字形尺寸）。
    var textBoxRect: CGRect {
        let inset = textBackgroundPadding
        return CGRect(origin: start, size: measuredTextSize)
            .insetBy(dx: -inset, dy: -inset)
    }

    /// 序号徽章直径（原图像素）：跟随共用的线宽，最小 20 px，保证数字可读。
    var numberDiameter: CGFloat {
        EditorToolOptions.WidthRole.badge.resolved(style.lineWidth)
    }

    /// 马赛克 / 模糊笔刷的直径（原图像素）；涂抹时按描边宽度展开成遮罩。
    var brushWidth: CGFloat {
        max(1, style.lineWidth)
    }

    /// 打码样式；未设置时按标注类型回退（马赛克 / 模糊工具各自的默认）。
    var redactionStyle: RedactionStyle {
        style.redactionStyle ?? (kind == .blur ? .blur : .mosaic)
    }

    /// 马赛克块大小 / 模糊半径（原图像素）。
    var filterAmount: CGFloat {
        switch kind {
        case .pixelate: return max(4, style.filterAmount ?? style.lineWidth * 3)
        case .blur: return max(3, style.filterAmount ?? style.lineWidth * 2)
        default: return 0
        }
    }

    /// 用 AppKit 字体量出文字尺寸（单行）；绘制与命中都用它。
    var measuredTextSize: CGSize {
        guard let text, !text.isEmpty else { return .zero }
        let font = NSFont.systemFont(ofSize: max(1, textFontSize), weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    var bounds: CGRect {
        if kind == .number {
            let diameter = numberDiameter
            return CGRect(
                x: start.x - diameter / 2,
                y: start.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        }
        if kind == .text {
            return textBoxRect
        }
        if kind.usesStrokePath, !points.isEmpty {
            var minX = points[0].x
            var minY = points[0].y
            var maxX = points[0].x
            var maxY = points[0].y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 7) -> Bool {
        // 「命中」= 这个位置按下后真的会改到东西。
        //
        // 矩形 / 椭圆的**内部是空白的**（它们是 `stroke`，不填充），
        // 以前用整框判定，导致框中间那片空白也能把标注抓走，
        // 光标在那里显示抓手却什么都没抓到。现在只认真正被画到的笔画。
        let reach = max(tolerance, style.lineWidth / 2 + 3)
        switch kind {
        case .line, .arrow:
            return distanceToSegment(point, start, end) <= reach
        case .freehand, .highlighter, .pixelate, .blur:
            guard points.count > 1 else {
                return points.first.map { distance($0, point) <= tolerance } ?? false
            }
            for index in 1..<points.count {
                if distanceToSegment(point, points[index - 1], points[index]) <= reach {
                    return true
                }
            }
            return false
        case .rectangle:
            // 四条边，不含内部空白。
            return hitTestRectEdges(point, rect: bounds, reach: reach)
        case .ellipse:
            // 椭圆周长，不含内部空白。
            return hitTestEllipseEdge(point, rect: bounds, reach: reach)
        case .text, .number, .spotlight, .magnifier:
            // 这几种在区域上是实心的（文字有字块、序号有徽章、
            // 聚光灯整体压暗、放大镜框内有内容），整框命中是诚实的。
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// 距矩形四条边是否在 `reach` 内（内部空白不算）。
    private func hitTestRectEdges(_ point: CGPoint, rect: CGRect, reach: CGFloat) -> Bool {
        // 高度为 0 的矩形退化成一条横线，宽度为 0 退化成竖线；
        // 两者都按线段处理，否则内缩区算不出来，整个外扩框都会被判命中。
        guard rect.width > 0, rect.height > 0 else {
            if rect.width <= 0, rect.height <= 0 {
                return distance(point, CGPoint(x: rect.midX, y: rect.midY)) <= reach
            }
            let a = CGPoint(x: rect.minX, y: rect.minY)
            let b = CGPoint(x: rect.maxX, y: rect.maxY)
            return distanceToSegment(point, a, b) <= reach
        }
        let outer = rect.insetBy(dx: -reach, dy: -reach)
        guard outer.contains(point) else { return false }
        // 落在「向内缩 reach」的核心区里 = 空白，不算命中。
        let inner = rect.insetBy(dx: reach, dy: reach)
        if inner.width > 0, inner.height > 0, inner.contains(point) {
            return false
        }
        return true
    }

    /// 距椭圆周长是否在 `reach` 内（内部空白不算）。
    private func hitTestEllipseEdge(_ point: CGPoint, rect: CGRect, reach: CGFloat) -> Bool {
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        guard radiusX > 0, radiusY > 0 else { return false }

        let centerX = rect.midX
        let centerY = rect.midY
        let dx = point.x - centerX
        let dy = point.y - centerY

        // 归一化椭圆距离：1 = 正好在周长上。
        let normalized = (dx * dx) / (radiusX * radiusX) + (dy * dy) / (radiusY * radiusY)

        // 把 `reach` 换算成归一化增量：用两轴的平均半径近似，
        // 误差在小 `reach` 下可以忽略，且不会在极扁的椭圆上算出 0 宽的热区。
        let scale = max((radiusX + radiusY) / 2, 1)
        let band = reach / scale

        return abs(sqrt(normalized) - 1) <= band
    }

    /// 选中虚线框范围：描边类标注把笔宽算进去，框住实际涂抹区域。
    var selectionBounds: CGRect {
        guard kind.usesStrokePath else { return bounds }
        return bounds.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> EditorAnnotation {
        var copy = self
        copy.start.x += dx
        copy.start.y += dy
        copy.end.x += dx
        copy.end.y += dy
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return distance(point, a)
        }
        let projection = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        let t = min(max(projection, 0), 1)
        let nearest = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(point, nearest)
    }
}
