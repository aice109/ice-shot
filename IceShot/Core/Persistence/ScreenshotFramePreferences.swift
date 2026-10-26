import Foundation

/// 「带壳」的样式偏好：记住**上次用过的样式**，下次开启时直接沿用。
///
/// 两条规则不能混：
///
/// 1. **每次截图仍然默认关闭带壳**。这里只记样式，不记开关——
///    默认开启会让「随手截一张」突然多出一圈留白，是个不受欢迎的意外。
/// 2. **样式本身要跨次记住**。用户调好的背景 / 边距 / 标题没必要每次重调。
///
/// 存储用原始值逐项映射，不给 `ScreenshotFrameStyle` 加 `Codable`：
/// 那份样式是导出渲染的输入，加序列化会把它和磁盘格式绑死，
/// 以后删掉一档背景就得写迁移。这里只存字符串，读不回来就退回默认。
nonisolated enum ScreenshotFramePreferences {
    /// `UserDefaults` 中各字段的 key。分字段存，坏掉一项不会连带其它项。
    static let chromeKey = "screenshotFrameChrome"
    static let appearanceKey = "screenshotFrameAppearance"
    static let backgroundKey = "screenshotFrameBackground"
    static let paddingKey = "screenshotFramePadding"
    static let showsShadowKey = "screenshotFrameShowsShadow"
    static let titleKey = "screenshotFrameTitle"

    /// 标题长度上限。
    ///
    /// 标题会被画进导出图：太长会撑出标题栏、也容易把整句话的隐私写死进图里。
    /// 超长直接截断，而不是拒绝保存。
    static let maximumTitleLength = 80

    /// 读取上次的样式；从没存过时返回 `nil`（调用方据此用来源默认样式）。
    static func style(from defaults: UserDefaults = .standard) -> ScreenshotFrameStyle? {
        guard defaults.object(forKey: chromeKey) != nil else { return nil }

        var style = ScreenshotFrameStyle.default
        style.chrome = ScreenshotFrameStyle.Chrome(rawValue: string(chromeKey, in: defaults))
            ?? ScreenshotFrameStyle.default.chrome
        style.appearance = ScreenshotFrameStyle.Appearance(rawValue: string(appearanceKey, in: defaults))
            ?? ScreenshotFrameStyle.default.appearance
        style.background = ScreenshotFrameStyle.Background(rawValue: string(backgroundKey, in: defaults))
            ?? ScreenshotFrameStyle.default.background
        style.padding = ScreenshotFrameStyle.Padding(rawValue: string(paddingKey, in: defaults))
            ?? ScreenshotFrameStyle.default.padding
        // 没写过的布尔读出来是 false，与默认的「有阴影」相反，
        // 所以只有明确存过才采信，否则留在默认值。
        if defaults.object(forKey: showsShadowKey) != nil {
            style.showsShadow = defaults.bool(forKey: showsShadowKey)
        }
        style.title = normalizedTitle(string(titleKey, in: defaults))
        return style
    }

    /// 保存样式。传 `nil` 等价于清空记忆。
    static func save(_ style: ScreenshotFrameStyle?, to defaults: UserDefaults = .standard) {
        guard let style else {
            clear(defaults)
            return
        }
        defaults.set(style.chrome.rawValue, forKey: chromeKey)
        defaults.set(style.appearance.rawValue, forKey: appearanceKey)
        defaults.set(style.background.rawValue, forKey: backgroundKey)
        defaults.set(style.padding.rawValue, forKey: paddingKey)
        defaults.set(style.showsShadow, forKey: showsShadowKey)
        defaults.set(normalizedTitle(style.title), forKey: titleKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        for key in [chromeKey, appearanceKey, backgroundKey, paddingKey, showsShadowKey, titleKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// 标题归一：去掉首尾空白（只有空格的标题不该画出一条空的标题栏）。
    static func normalizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumTitleLength else { return trimmed }
        return String(trimmed.prefix(maximumTitleLength))
    }

    private static func string(_ key: String, in defaults: UserDefaults) -> String {
        defaults.string(forKey: key) ?? ""
    }
}
