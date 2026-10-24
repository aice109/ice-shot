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
    static let clusterSpacing: CGFloat = 10
    /// 图标点击区：比字形大一圈，按钮之间才有呼吸。
    static let iconSide: CGFloat = 18

    /// 操作条所在的位置。
    enum Context: Equatable, Sendable {
        /// 截图后的就地浮层：压在截图上，带关闭按钮，没有裁剪与变换。
        case overlay
        /// 标注编辑器窗口：常规窗口，没有关闭按钮（走标题栏），带裁剪与变换。
        case editor
    }

    /// 一条操作条上会出现的按钮，按展示顺序排列。
    enum Item: String, CaseIterable, Sendable {
        /// 一个工具（具体工具由 `EditorTool` 决定，这里只占一个位置）。
        case tool
        /// 「变换」按钮：旋转 / 翻转四项（只给编辑器窗口）。
        case transform
        /// 「取字」。
        case textPicking
        /// 选中已有标注时的「该类型选项」按钮。
        case selectedOptions
        /// 撤销。
        case undo
        /// 重做。
        case redo
        /// 复制（主操作，强调色）。
        case copy
        /// 保存。
        case save
        /// 贴图。
        case pin
        /// 关闭（只在浮层；编辑器窗口走标题栏的关闭按钮）。
        case close

        var isTool: Bool { self == .tool }
    }

    /// 工具胶囊里的内容顺序：工具 → 变换 → 取字 → 选中态选项。
    static let toolCluster: [Item] = [.tool, .transform, .textPicking, .selectedOptions]
    /// 输出胶囊里的内容顺序：撤销 → 重做 → 复制 → 保存 → 贴图 → 关闭。
    static let actionCluster: [Item] = [.undo, .redo, .copy, .save, .pin, .close]

    /// 某个入口、当前状态下应该出现哪些按钮。
    ///
    /// - Parameters:
    ///   - context: 入口（浮层 / 编辑器窗口）。
    ///   - showsCropTool: 是否把「裁剪」放进工具组。就地浮层的选区本身就是裁剪范围，
    ///     再裁一次会让选区与图像坐标错位，所以浮层传 `false`。
    ///   - hasSelectedAnnotationOptions: 选中的标注有没有可调参数。
    ///   - hasSelectedAnnotation: 当前是否选中了标注（有选中才可能出现「删除」）。
    static func items(
        in context: Context,
        showsCropTool: Bool,
        hasSelectedAnnotationOptions: Bool
    ) -> [Item] {
        toolCluster.filter { item in
            switch item {
            case .transform: return context == .editor
            case .selectedOptions: return hasSelectedAnnotationOptions
            default: return true
            }
        } + actionCluster.filter { item in
            switch item {
            case .close: return context == .overlay
            default: return true
            }
        }
    }

    /// 工具组里要显示的工具（浮层不含裁剪，两处都不含「无工具」哨兵）。
    static func tools(showsCropTool: Bool) -> [EditorTool] {
        EditorTool.allCases.filter { tool in
            tool.appearsOnToolbar && (showsCropTool || tool != .crop)
        }
    }

    /// 该分组在当前入口下有没有可显示的工具（增强组为空时不插入空段）。
    static func shows(_ group: EditorTool.Group, showsCropTool: Bool) -> Bool {
        !EditorTool.tools(in: group).filter {
            $0.appearsOnToolbar && (showsCropTool || $0 != .crop)
        }.isEmpty
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
            case .rotateClockwise: return "顺时针旋转 90°"
            case .rotateCounterClockwise: return "逆时针旋转 90°"
            case .flipHorizontal: return "水平翻转"
            case .flipVertical: return "垂直翻转"
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
