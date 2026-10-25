import CoreGraphics
import Foundation

/// 标注操作条上的「按钮」清单（纯数据）。
///
/// 操作条 `MarkupToolbar` 被两个入口共用：截图后的就地浮层（无标题栏的 `NSPanel`）、
/// 标注编辑器窗口（常规窗口）。**按钮清单、顺序、分组、留白只在这里写一次**，
/// 两个入口只是按同一个序列渲染，所以两边样式天然一致。
///
/// 分层原因：`NSSegmentedControl` 那套原生工具栏与浮层的玻璃胶囊是两套完全不同的外观，
/// 用户在真机上看到的是「同一个功能两个样」。现在统一成浮层那套玻璃胶囊，
/// 编辑器窗口保留系统标题栏与状态栏，只把工具条换成同一条。
enum MarkupToolbarLayout {
    /// 工具组与其它按钮之间的留白，以及工具组内部「绘制 ‖ 增强」之间的留白。
    static let itemSpacing: CGFloat = 6
    /// 组间额外留白：叠加在 `itemSpacing` 上（6 + 8 = 14）。组靠留白分开，不用分隔线。
    static let groupExtraGap: CGFloat = 8
    /// 胶囊之间的留白。
    ///
    /// 与 `MarkupToolbar` 里 `GlassGroup(spacing: 12)` 配合：间距落在吸附距离之内，
    /// 两组胶囊靠得近时会真实融成一体（液态吸附），拉开时又各自独立。
    static let clusterSpacing: CGFloat = 10
    /// 图标点击区：比字形大一圈，按钮之间才有呼吸。
    ///
    /// 20 pt 是 macOS 工具栏的常见光学尺寸；18 pt 下 `light.beacon.max`、
    /// `plus.magnifyingglass` 这类多层字形会糊成一团。
    static let iconSide: CGFloat = 20
    /// 「更多」按钮的图标：始终是 `chevron.right`，靠**旋转 90°** 表达展开 / 收起。
    ///
    /// 用旋转而不是换图形：换 SF Symbol 是两个不同图标在跳，旋转才是一次连贯的形变。
    static let moreSymbolName = "chevron.right"
    /// 「更多」按钮的水平 padding：胶囊形比普通图标按钮宽，这是它「是容器不是工具」的形态信号。
    static let moreButtonHorizontalPadding: CGFloat = 8
    /// 「更多」按钮的高度：与图标点击区一致，保证胶囊不胖于方形按钮。
    static let moreButtonHeight: CGFloat = iconSide + 8

    // MARK: - 图标与文字

    /// 操作条**只显示图标，不显示文字**。
    ///
    /// 曾经试过「图标 + 文字」：11 个工具 + 6 个输出全带文字约需 950 pt，
    /// 13 寸屏减去选区边缘后就顶到屏幕边界；而只给高频项加文字，
    /// 又会让同一条胶囊里的按钮一宽一窄、重心散掉。
    /// 每个工具都有 `.help` 提示与单键快捷键，图标 + 悬停说明已经够用。
    static let showsButtonTitles = false

    /// 操作条所在的位置。
    enum Context: Equatable, Sendable {
        /// 截图后的就地浮层：压在截图上，带关闭按钮，没有裁剪与变换。
        case overlay
        /// 标注编辑器窗口：常规窗口，没有关闭按钮（走标题栏），带裁剪与变换。
        case editor
    }

    /// 工具胶囊里的一格（按展示顺序）。
    ///
    /// **顺序只在这份序列里写一次**。新增工具时改这里即可，`MarkupToolbar`
    /// 只负责按序列渲染，不再自己从 `EditorTool` 的属性反推分组的排布。
    enum Item: Equatable, Sendable {
        /// 一个独占一格的工具（裁剪 / 箭头 / 文字 / 马赛克）。
        case tool(EditorTool)
        /// 一个多子型组按钮（形状 / 画笔 / 更多）。
        case group(EditorTool.ToolGroup)
        /// 「变换」按钮：旋转 / 翻转四项（只给编辑器窗口）。
        case transform
        /// 「取字」。
        case textPicking
        /// 选中已有标注时的「该类型选项」按钮。
        case selectedOptions
    }

    /// 输出胶囊里的一格：撤销 → 重做 → 复制 → 保存 → 贴图 → 关闭。
    enum OutputItem: Equatable, Sendable {
        case undo
        case redo
        case copy
        case save
        case pin
        case close
    }

    /// 工具胶囊的内容顺序：
    /// 选择 → 裁剪 → 形状▾ → 箭头 → 画笔▾ → 文字 → 马赛克 → [选中态选项] → 取字 → 变换 → 更多▾。
    ///
    /// 序号 / 聚光灯 / 放大镜 三项不单独占格，它们只在「更多」展开时出现——
    /// 展开位置由 `group(.more)` 决定，展开内容来自 `EditorTool.ToolGroup.more.members`。
    static let toolCluster: [Item] = [
        .tool(.select),
        .tool(.crop),
        .group(.shape),
        .tool(.arrow),
        .group(.brush),
        .tool(.text),
        .tool(.pixelate),
        .selectedOptions,
        .textPicking,
        .transform,
        .group(.more),
    ]

    /// 输出胶囊的内容顺序。
    static let actionCluster: [OutputItem] = [.undo, .redo, .copy, .save, .pin, .close]

    /// 工具胶囊里独占一格的工具（按展示顺序，浮层不含裁剪）。
    static func tools(showsCropTool: Bool) -> [EditorTool] {
        toolCluster.compactMap { item in
            guard case .tool(let tool) = item else { return nil }
            return showsCropTool || tool != .crop ? tool : nil
        }
    }

    /// 工具胶囊里要多子型组按钮的组（形状 / 画笔 / 更多）。
    static func groups(showsCropTool: Bool) -> [EditorTool.ToolGroup] {
        toolCluster.compactMap { item in
            guard case .group(let group) = item else { return nil }
            return shows(group, showsCropTool: showsCropTool) ? group : nil
        }
    }

    /// 该多子型组在当前入口下有没有可显示的工具。
    ///
    /// 现有的三个组都不含裁剪，所以这里只看组本身是否为空；
    /// 保留 `showsCropTool` 参数是为了将来把裁剪塞进组时不用改调用点。
    static func shows(_ group: EditorTool.ToolGroup, showsCropTool: Bool) -> Bool {
        _ = showsCropTool
        return !group.members.isEmpty
    }

    /// 某个入口、当前状态下应该出现哪些**工具 capsule 的格子**。
    ///
    /// - Parameters:
    ///   - context: 入口（浮层 / 编辑器窗口）。
    ///   - showsCropTool: 是否把「裁剪」放进工具胶囊。就地浮层的选区本身就是裁剪范围，
    ///     再裁一次会让选区与图像坐标错位，所以浮层传 `false`。
    ///   - hasSelectedAnnotationOptions: 选中的标注有没有可调参数。
    static func items(
        in context: Context,
        showsCropTool: Bool,
        hasSelectedAnnotationOptions: Bool
    ) -> [Item] {
        toolCluster.filter { item in
            switch item {
            case .tool(let tool):
                return showsCropTool || tool != .crop
            case .group(let group):
                return shows(group, showsCropTool: showsCropTool)
            case .transform:
                return context == .editor
            case .selectedOptions:
                return hasSelectedAnnotationOptions
            case .textPicking:
                return true
            }
        }
    }

    /// 输出胶囊里当前状态应该出现的格子。
    static func outputItems(in context: Context) -> [OutputItem] {
        actionCluster.filter { item in
            item != .close || context == .overlay
        }
    }

    /// 「变换」四项：编辑器窗口的旋转 / 翻转命令。
    ///
    /// 它们是**一次性图像变换**（不是绘制工具），所以不做成工具按钮，而是点开一个
    /// 与「工具二级选项」同款的原生 `.popover`——同一种交互语言，不另造下拉菜单。
    enum Transform: String, CaseIterable, Sendable {
        case rotateClockwise
        case rotateCounterClockwise
        case flipHorizontal
        case flipVertical

        var title: String {
            switch self {
            case .rotateClockwise: return String(localized: "顺时针旋转 90°")
            case .rotateCounterClockwise: return String(localized: "逆时针旋转 90°")
            case .flipHorizontal: return String(localized: "水平翻转")
            case .flipVertical: return String(localized: "垂直翻转")
            }
        }

        var symbolName: String {
            switch self {
            case .rotateClockwise: return "rotate.right"
            case .rotateCounterClockwise: return "rotate.left"
            case .flipHorizontal: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
            case .flipVertical: return "arrow.up.and.down.righttriangle.up.righttriangle.down"
            }
        }

        /// 菜单 / 提示里显示的快捷键（`.lowercased()` 后与 `NSEvent.charactersIgnoringModifiers` 比对）。
        var shortcut: String {
            switch self {
            case .rotateClockwise: return "⌘R"
            case .rotateCounterClockwise: return "⇧⌘R"
            case .flipHorizontal: return "⌃⌘H"
            case .flipVertical: return "⌃⌘V"
            }
        }
    }
}
