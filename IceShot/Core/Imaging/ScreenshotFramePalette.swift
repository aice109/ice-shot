import CoreGraphics

/// 带壳导出图的固定内容色。
///
/// 与标注色板同一条理由：这些颜色会烧进图片，必须稳定，
/// 不能跟着 App 的浅色 / 深色模式或系统强调色变化。
enum ScreenshotFramePalette {
    struct Theme {
        let titleBarTop: CGColor
        let titleBarBottom: CGColor
        let body: CGColor
        let separator: CGColor
        let border: CGColor
        let title: CGColor
    }

    struct TrafficLight {
        let fill: CGColor
        let stroke: CGColor
    }

    struct Gradient {
        let start: CGColor
        let end: CGColor
    }

    static let close = TrafficLight(
        fill: color(0xFF5F57),
        stroke: color(0xE0443E)
    )
    static let minimize = TrafficLight(
        fill: color(0xFEBC2E),
        stroke: color(0xDEA123)
    )
    static let zoom = TrafficLight(
        fill: color(0x28C840),
        stroke: color(0x1AAB29)
    )

    /// 自动外观已经解析成 `.light` / `.dark` 后再进来。
    static func theme(for appearance: ScreenshotFrameStyle.Appearance) -> Theme {
        switch appearance {
        case .dark:
            return Theme(
                titleBarTop: color(0x303032),
                titleBarBottom: color(0x252527),
                body: color(0x1C1C1E),
                separator: color(0xFFFFFF, alpha: 0.10),
                border: color(0xFFFFFF, alpha: 0.10),
                title: color(0xFFFFFF, alpha: 0.60)
            )
        case .light, .automatic:
            return Theme(
                titleBarTop: color(0xFAFAFA),
                titleBarBottom: color(0xF0F0F0),
                body: color(0xFFFFFF),
                separator: color(0x000000, alpha: 0.08),
                border: color(0x000000, alpha: 0.08),
                title: color(0x3C3C43, alpha: 0.60)
            )
        }
    }

    /// 透明底返回 `nil`。
    static func gradient(for background: ScreenshotFrameStyle.Background) -> Gradient? {
        switch background {
        case .transparent:
            return nil
        case .graphite:
            return Gradient(start: color(0x3A3A3C), end: color(0x1C1C1E))
        case .ocean:
            return Gradient(start: color(0x6FA8D9), end: color(0x1F4E79))
        case .sunrise:
            return Gradient(start: color(0xF6D5B8), end: color(0xC97B63))
        case .aurora:
            return Gradient(start: color(0x9BE3D8), end: color(0x3A5A78))
        }
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
