import CoreGraphics
import Foundation

/// 导出截图时套在外面的「壳」。纯数据，可跨并发域传递。
///
/// 壳是**导出图的一部分**，不是界面材质：颜色与几何必须固定，
/// 不能随 App 的浅色 / 深色模式变化，否则同一张图每次导出结果都不一样。
///
/// 标记 `nonisolated`：渲染器（`ScreenshotFrameComposer`）在非主 actor 上读它。
nonisolated struct ScreenshotFrameStyle: Hashable, Sendable {
    /// 壳形态。
    ///
    /// 注意：能选哪些**不由用户决定**，而由截图的来源决定。
    /// 窗口截图里已经带着自己的红黄绿，再套一层窗口壳就是双层交通灯，
    /// 所以那种图只允许 `.shadowOnly`（见 `ScreenshotFrameStyle.allowedChrome(for:)`）。
    enum Chrome: String, CaseIterable, Hashable, Sendable {
        /// macOS 窗口：标题栏 + 红黄绿交通灯 + 可选标题。
        case window
        /// 仅圆角、描边、投影与背景，不再加一层标题栏。
        /// 给「本身已经是窗口截图」的图用，避免双层交通灯。
        case shadowOnly
        /// MacBook 机身。只给整屏截图（全屏 / 全部显示器），
        /// 实际渲染转交 `DeviceFrameComposer`。
        case macbook

        var title: String {
            switch self {
            case .window: return String(localized: "窗口")
            case .shadowOnly: return String(localized: "仅阴影")
            case .macbook: return String(localized: "MacBook")
            }
        }

        /// 这一档是不是设备壳（要转交另一个渲染器）。
        var usesDeviceFrame: Bool {
            self == .macbook
        }
    }

    /// 某个来源下允许的壳形态。
    ///
    /// 三档来源规则：
    /// - 窗口：只有 `.shadowOnly`，画面里已经有交通灯；
    /// - 全屏 / 全部显示器：`.macbook` 顶替 `.window`——整屏内容套一扇假窗口标题栏很违和，
    ///   套机身才说得通；
    /// - 区域 / 长截图：保持原样两档。
    static func allowedChrome(for source: ScreenshotSource) -> [Chrome] {
        switch source {
        case .window:
            return [.shadowOnly]
        case .display, .allDisplays:
            return [.macbook, .shadowOnly]
        case .region, .scroll:
            return [.window, .shadowOnly]
        }
    }

    /// 窗口外观。自动模式按截图顶部亮度决定，不读系统外观。
    enum Appearance: String, CaseIterable, Hashable, Sendable {
        case automatic
        case light
        case dark

        var title: String {
            switch self {
            case .automatic: return String(localized: "自动")
            case .light: return String(localized: "浅色")
            case .dark: return String(localized: "深色")
            }
        }
    }

    /// 壳外面的背景。
    enum Background: String, CaseIterable, Hashable, Sendable {
        case transparent
        case graphite
        case ocean
        case sunrise
        case aurora

        var title: String {
            switch self {
            case .transparent: return String(localized: "透明")
            case .graphite: return String(localized: "石墨")
            case .ocean: return String(localized: "海蓝")
            case .sunrise: return String(localized: "晨曦")
            case .aurora: return String(localized: "极光")
            }
        }
    }

    /// 壳与画布边缘之间的留白。投影需要这段空间，否则会被裁掉。
    enum Padding: String, CaseIterable, Hashable, Sendable {
        case small
        case medium
        case large

        /// 1u 基准下的留白。
        var baseValue: CGFloat {
            switch self {
            case .small: return 32
            case .medium: return 64
            case .large: return 96
            }
        }

        var title: String {
            switch self {
            case .small: return String(localized: "小")
            case .medium: return String(localized: "中")
            case .large: return String(localized: "大")
            }
        }
    }

    var chrome: Chrome = .window
    /// 设备壳的机身配色。只对 `.macbook` 有意义。
    ///
    /// 放在这里而不是只存在 `EditorModel` 里：预览与导出都经过 `compose(style:)`，
    /// 如果机身配色不当成样式的一部分，就会出现「改了机身但预览不变」。
    var deviceFinish: DeviceFrameStyle.Finish = .silver
    var appearance: Appearance = .automatic
    var background: Background = .transparent
    var padding: Padding = .medium
    var showsShadow: Bool = true
    /// 窗口标题；空字符串表示不画标题。默认不自动填窗口标题，避免把隐私信息带进导出图。
    var title: String = ""

    static let `default` = ScreenshotFrameStyle()
}
