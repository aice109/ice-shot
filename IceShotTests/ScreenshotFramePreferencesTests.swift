import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 带壳偏好的持久化。
///
/// 两个必须同时成立、又容易互相冲突的约定：
///
/// 1. **每次截图仍然默认关闭带壳**——记住样式不等于记住开关；
/// 2. **样式本身跨次记住**——用户调好的背景 / 边距 / 标题不用每次重调。
///
/// 每个用例都用独立 `UserDefaults` 域，避免测试之间互相污染。
@MainActor
struct ScreenshotFramePreferencesTests {
    /// 建一个用完即弃的 defaults 域。
    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "IceShotTests.FramePreferences.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建隔离的 UserDefaults 域：\(suiteName)")
            return .standard
        }
        return defaults
    }

    // MARK: - 存取

    @Test("从没存过时没有记忆")
    func emptyByDefault() {
        let defaults = isolatedDefaults()
        #expect(ScreenshotFramePreferences.style(from: defaults) == nil)
    }

    @Test("整份样式存进去能原样读回")
    func roundTripsWholeStyle() throws {
        let defaults = isolatedDefaults()
        var style = ScreenshotFrameStyle.default
        style.chrome = .shadowOnly
        style.appearance = .dark
        style.background = .aurora
        style.padding = .large
        style.showsShadow = false
        style.title = "示例窗口"

        ScreenshotFramePreferences.save(style, to: defaults)
        let loaded = try #require(ScreenshotFramePreferences.style(from: defaults))
        #expect(loaded == style)
    }

    @Test("清除后回到没有记忆")
    func clearRemovesEverything() {
        let defaults = isolatedDefaults()
        ScreenshotFramePreferences.save(.default, to: defaults)
        #expect(ScreenshotFramePreferences.style(from: defaults) != nil)

        ScreenshotFramePreferences.clear(defaults)
        #expect(ScreenshotFramePreferences.style(from: defaults) == nil)
    }

    @Test("存 nil 等价于清除")
    func savingNilClears() {
        let defaults = isolatedDefaults()
        ScreenshotFramePreferences.save(.default, to: defaults)
        ScreenshotFramePreferences.save(nil, to: defaults)
        #expect(ScreenshotFramePreferences.style(from: defaults) == nil)
    }

    // MARK: - 坏数据

    @Test("枚举值被改坏时逐项退回默认，不整份丢弃")
    func corruptEnumFallsBackPerField() throws {
        let defaults = isolatedDefaults()
        // 先写一份完整有效的，再把背景改成一个不存在的档位。
        ScreenshotFramePreferences.save(.default, to: defaults)
        defaults.set("neon", forKey: ScreenshotFramePreferences.backgroundKey)
        // 边距是好的，应该保留。
        defaults.set(ScreenshotFrameStyle.Padding.small.rawValue, forKey: ScreenshotFramePreferences.paddingKey)

        let loaded = try #require(ScreenshotFramePreferences.style(from: defaults))
        #expect(loaded.background == ScreenshotFrameStyle.default.background)
        #expect(loaded.padding == .small, "没坏的那项不该被连带丢弃")
    }

    @Test("没存过阴影开关时保留默认的「有阴影」")
    func missingShadowKeepsDefault() throws {
        let defaults = isolatedDefaults()
        // 只写 chrome，让别的字段都不存在。
        defaults.set(ScreenshotFrameStyle.Chrome.window.rawValue, forKey: ScreenshotFramePreferences.chromeKey)

        let loaded = try #require(ScreenshotFramePreferences.style(from: defaults))
        // 直接读 bool 会得到 false，与默认相反——这里必须仍是 true。
        #expect(loaded.showsShadow == ScreenshotFrameStyle.default.showsShadow)
        #expect(loaded.showsShadow)
    }

    @Test("明确存过 false 时能读回 false")
    func explicitFalseShadowIsKept() throws {
        let defaults = isolatedDefaults()
        var style = ScreenshotFrameStyle.default
        style.showsShadow = false
        ScreenshotFramePreferences.save(style, to: defaults)

        let loaded = try #require(ScreenshotFramePreferences.style(from: defaults))
        #expect(loaded.showsShadow == false)
    }

    // MARK: - 标题

    @Test("标题去掉首尾空白")
    func titleIsTrimmed() {
        #expect(ScreenshotFramePreferences.normalizedTitle("  窗口标题  ") == "窗口标题")
        #expect(ScreenshotFramePreferences.normalizedTitle("\n标题\n") == "标题")
        // 只有空白等于没写：不该画出一条空标题栏。
        #expect(ScreenshotFramePreferences.normalizedTitle("   ") == "")
    }

    @Test("超长标题被截断到上限")
    func longTitleIsTruncated() {
        let long = String(repeating: "长", count: ScreenshotFramePreferences.maximumTitleLength + 50)
        let result = ScreenshotFramePreferences.normalizedTitle(long)
        #expect(result.count == ScreenshotFramePreferences.maximumTitleLength)
    }

    @Test("存进去的标题也做归一")
    func savedTitleIsNormalized() throws {
        let defaults = isolatedDefaults()
        var style = ScreenshotFrameStyle.default
        style.title = "   带空格的标题   "
        ScreenshotFramePreferences.save(style, to: defaults)

        let loaded = try #require(ScreenshotFramePreferences.style(from: defaults))
        #expect(loaded.title == "带空格的标题")
    }

    // MARK: - 与模型的配合

    @Test("下次新建模型时沿用上次的样式")
    func newModelPicksUpRememberedStyle() throws {
        let defaults = isolatedDefaults()

        var style = ScreenshotFrameStyle.default
        style.background = .sunrise
        style.padding = .small
        style.title = "记住我"
        ScreenshotFramePreferences.save(style, to: defaults)

        let model = EditorModel(
            image: try makeImage(),
            title: "测试",
            framePreferenceDefaults: defaults
        )
        model.setFrameEnabled(true)

        let active = try #require(model.frameStyle)
        #expect(active.background == .sunrise)
        #expect(active.padding == .small)
        #expect(active.title == "记住我")
    }

    @Test("新模型仍然默认关闭带壳")
    func newModelStartsWithFrameDisabled() throws {
        let defaults = isolatedDefaults()
        ScreenshotFramePreferences.save(.default, to: defaults)

        let model = EditorModel(
            image: try makeImage(),
            title: "测试",
            framePreferenceDefaults: defaults
        )
        // 记住的是样式，不是开关：每次截图仍然默认不带壳。
        #expect(model.frameStyle == nil)
        #expect(!model.isFrameEnabled)
    }

    @Test("改动样式会被记住")
    func changingStyleIsRemembered() throws {
        let defaults = isolatedDefaults()
        let model = EditorModel(
            image: try makeImage(),
            title: "测试",
            framePreferenceDefaults: defaults
        )
        model.setFrameEnabled(true)

        var style = try #require(model.frameStyle)
        style.background = .ocean
        model.setFrameStyle(style)

        // 直接读偏好层，确认写盘了（而不是只改了内存）。
        let stored = try #require(ScreenshotFramePreferences.style(from: defaults))
        #expect(stored.background == .ocean)
    }

    @Test("关掉带壳不会把记忆清掉")
    func disablingKeepsRememberedStyle() throws {
        let defaults = isolatedDefaults()
        let model = EditorModel(
            image: try makeImage(),
            title: "测试",
            framePreferenceDefaults: defaults
        )
        model.setFrameEnabled(true)

        var style = try #require(model.frameStyle)
        style.background = .graphite
        model.setFrameStyle(style)

        model.setFrameEnabled(false)

        // 关掉只是本次不带壳，下次开启仍该拿到上次真正用过的样式。
        let stored = try #require(ScreenshotFramePreferences.style(from: defaults))
        #expect(stored.background == .graphite)
    }

    @Test("记住的样式 + 窗口来源：仍然避开双层交通灯")
    func windowSourceOverridesRememberedChrome() throws {
        let defaults = isolatedDefaults()

        var remembered = ScreenshotFrameStyle.default
        remembered.chrome = .window
        remembered.background = .aurora   // 用户调过的背景要留着
        ScreenshotFramePreferences.save(remembered, to: defaults)

        let model = EditorModel(
            image: try makeImage(),
            title: "测试",
            framePreferenceDefaults: defaults
        )
        // 窗口来源应把壳形态改成仅阴影，但保留用户调好的背景。
        model.applyDefaultFrameStyle(for: .window)
        model.setFrameEnabled(true)

        let active = try #require(model.frameStyle)
        #expect(active.chrome == .shadowOnly)
        #expect(active.background == .aurora)
    }

    @Test("区域截图不受窗口来源例外影响")
    func regionSourceKeepsRememberedChrome() throws {
        let defaults = isolatedDefaults()

        var remembered = ScreenshotFrameStyle.default
        remembered.chrome = .window
        remembered.background = .aurora
        ScreenshotFramePreferences.save(remembered, to: defaults)

        let model = EditorModel(
            image: try makeImage(),
            title: "测试",
            framePreferenceDefaults: defaults
        )
        model.applyDefaultFrameStyle(for: .region)
        model.setFrameEnabled(true)

        let active = try #require(model.frameStyle)
        #expect(active.chrome == .window)
        #expect(active.background == .aurora)
    }

    // MARK: - 辅助

    private func makeImage() throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 100,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        return try #require(context.makeImage())
    }
}
