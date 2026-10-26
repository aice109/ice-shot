import CoreGraphics
import Foundation

/// 设备壳（MacBook 机身）的样式。
///
/// 与 `ScreenshotFrameStyle`（窗口壳）是两个独立类型，不是它的一个枚举值：
/// 两者隐喻不同（产品照 vs 窗口）、几何完全不同、渲染器也不同。
/// `ScreenshotFrameStyle.Chrome.macbook` 只是入口，内部转交 `DeviceFrameComposer`。
nonisolated struct DeviceFrameStyle: Hashable, Sendable {
    /// 机身配色。
    enum Finish: String, CaseIterable, Hashable, Sendable {
        case silver
        case spaceGray

        var title: String {
            switch self {
            case .silver: return String(localized: "银色")
            case .spaceGray: return String(localized: "深空灰")
            }
        }
    }

    /// 壳外面的背景。复用窗口壳那五档，避免同一个 App 出现两套背景语言。
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

        /// 映射到窗口壳的同一档，让两个渲染器共用一份渐变定义。
        var shared: ScreenshotFrameStyle.Background {
            switch self {
            case .transparent: return .transparent
            case .graphite: return .graphite
            case .ocean: return .ocean
            case .sunrise: return .sunrise
            case .aurora: return .aurora
            }
        }
    }

    /// 外边距。设备壳的机身边缘本身就占视觉重量，留白比窗口壳略小。
    enum Padding: String, CaseIterable, Hashable, Sendable {
        case small
        case medium
        case large

        var baseValue: CGFloat {
            switch self {
            case .small: return 28
            case .medium: return 52
            case .large: return 76
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

    var finish: Finish = .silver
    var background: Background = .graphite
    var padding: Padding = .medium
    var showsShadow: Bool = true

    static let `default` = DeviceFrameStyle()

    /// 从窗口壳样式推导出一个设备壳样式。
    ///
    /// 用户在全屏截图里选了「MacBook」这一档时，背景 / 边距 / 阴影这些已经调好的东西
    /// 不该丢掉——它们在两个渲染器里语义相同。壳形态本身由各自渲染器决定。
    static func derived(from frame: ScreenshotFrameStyle) -> DeviceFrameStyle {
        var style = DeviceFrameStyle()
        style.background = Background(rawValue: frame.background.rawValue) ?? .graphite
        style.padding = Padding(rawValue: frame.padding.rawValue) ?? .medium
        style.showsShadow = frame.showsShadow
        style.finish = frame.deviceFinish
        return style
    }
}
