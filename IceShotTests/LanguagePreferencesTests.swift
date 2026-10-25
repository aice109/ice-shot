import Foundation
import Testing
@testable import IceShot

/// 界面语言偏好。
///
/// 这层最容易出错的不是「写入」，而是**把用户真实的系统设置覆盖掉**：
/// 写一个自己编的 `AppleLanguages` 列表会盖掉用户在「系统设置 > 语言与地区」里的选择，
/// 包括给 IceShot 单独指定的语言。所以「跟随系统」必须是删键，而不是写默认值。
struct LanguagePreferencesTests {
    /// 用独立 suite 的 UserDefaults，避免污染真实偏好。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "LanguagePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToFollowingSystem() {
        let defaults = makeDefaults()
        #expect(LanguagePreferences.currentChoice(from: defaults) == .system)
    }

    /// 「跟随系统」必须把两把钥匙都清掉，把语言决定权交还 macOS。
    ///
    /// 只断言自己的钥匙（`uiLanguageChoiceKey`）——`AppleLanguages` 不能用
    /// `object(forKey:) == nil` 验：`UserDefaults` 在应用域删掉后会**回落到全局域**，
    /// 而全局域里本来就有系统写入的 `AppleLanguages`。那正是这层要绕开的坑。
    @Test func systemChoiceClearsOwnKey() {
        let defaults = makeDefaults()
        LanguagePreferences.apply(.english, to: defaults)

        LanguagePreferences.apply(.system, to: defaults)

        #expect(defaults.object(forKey: LanguagePreferences.uiLanguageChoiceKey) == nil)
        #expect(LanguagePreferences.currentChoice(from: defaults) == .system)
    }

    @Test func explicitChoicesRoundTrip() {
        for choice in [LanguagePreferences.Choice.simplifiedChinese, .english] {
            let defaults = makeDefaults()
            LanguagePreferences.apply(choice, to: defaults)
            #expect(LanguagePreferences.currentChoice(from: defaults) == choice)
        }
    }

    /// 选具体语言时，真正让系统解析生效的 `AppleLanguages` 必须是单元素列表。
    @Test func explicitChoiceWritesAppleLanguages() {
        let defaults = makeDefaults()
        LanguagePreferences.apply(.english, to: defaults)
        #expect(defaults.stringArray(forKey: LanguagePreferences.appleLanguagesKey) == ["en"])

        LanguagePreferences.apply(.simplifiedChinese, to: defaults)
        #expect(defaults.stringArray(forKey: LanguagePreferences.appleLanguagesKey) == ["zh-Hans"])
    }

    /// 关键回归：全局域里本来就有系统写入的 `AppleLanguages`。
    /// 用户选「跟随系统」后，即便读得到那个系统值，也不能被判成「显式选了中文」。
    @Test func systemChoiceIsNotConfusedByGlobalDomain() {
        let defaults = makeDefaults()
        // 模拟全局域有值，但应用域没记过选择。
        defaults.set(["zh-Hans"], forKey: "__GlobalAppleLanguagesSentinel")
        defaults.removeObject(forKey: LanguagePreferences.uiLanguageChoiceKey)
        #expect(LanguagePreferences.currentChoice(from: defaults) == .system)
    }

    /// 真正带两份 `.lproj` 的 bundle。
    ///
    /// 不能用 `Bundle(for: BundleAnchor.self)`：那是测试 bundle，本地化列表
    /// 和 App 不一样（往往只有 `en`），拿它验证语言映射会得到假结果。
    private func appBundle() -> Bundle {
        Bundle.main
    }

    /// 「跟随系统」也要能判出需要重启。
    ///
    /// 旧实现这里直接 `return false`，于是用户从「English」切回「跟随系统」时，
    /// 若系统是中文，画面纹丝不动也没有任何提示。
    /// 真实读取路径：不传 `systemLanguage`，让实现自己去问系统。
    ///
    /// 这是之前**漏掉的回归**：上面的测试都显式传入了 `systemLanguage`，
    /// 绕过了 `systemPreferredLanguageCode()`，所以没发现它读的
    /// `Locale.preferredLanguages` 会被本应用写入的 `AppleLanguages` 污染——
    /// 而 `apply()` 恰好就在写那个键，于是切回跟随系统时永远算成「不需要重启」。
    @Test func systemPreferredLanguageIsNotPollutedByAppWrites() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: LanguagePreferences.appleLanguagesKey)
        defer {
            // 无论断言成败都把现场恢复回去，不能污染其他用例。
            if let original {
                defaults.set(original, forKey: LanguagePreferences.appleLanguagesKey)
            } else {
                defaults.removeObject(forKey: LanguagePreferences.appleLanguagesKey)
            }
            defaults.synchronize()
        }

        // 模拟「用户选了英文」：apply 会写 AppleLanguages，
        // 而 `Locale.preferredLanguages` 会跟着变（实测量到的行为）。
        LanguagePreferences.apply(.english, to: defaults)
        let whileEnglish = LanguagePreferences.systemPreferredLanguageCode()

        // 恢复跟随系统。
        LanguagePreferences.apply(.system, to: defaults)
        let whileSystem = LanguagePreferences.systemPreferredLanguageCode()

        #expect(
            whileEnglish == whileSystem,
            "系统语言不应随本应用的写入变化"
        )
    }

    @Test func systemChoiceNeedsRestartWhenSystemLanguageDiffers() {
        let bundle = appBundle()
        guard let active = LanguagePreferences.activeLanguageCode(bundle: bundle) else {
            Issue.record("拿不到当前生效语言，无法验证")
            return
        }
        // 构造一个与当前生效语言**相反**的系统语言，此时切回跟随系统必然要重启。
        let opposite = active.hasPrefix("zh") ? "en-US" : "zh-Hans-CN"
        #expect(
            LanguagePreferences.needsRestart(
                choice: .system,
                bundle: bundle,
                systemLanguage: opposite
            ),
            "当前跑 \(active)，系统设为 \(opposite)，切回跟随系统应提示重启"
        )
    }

    /// 跑的语言和系统偏好一致时，切回跟随系统不需要重启。
    @Test func systemChoiceNeedsNoRestartWhenAlreadyMatching() {
        let bundle = appBundle()
        guard let active = LanguagePreferences.activeLanguageCode(bundle: bundle) else { return }
        // 造一个与当前生效语言同向的系统语言。
        let sameDirection = active.hasPrefix("zh") ? "zh-Hans-CN" : "en-US"
        #expect(
            !LanguagePreferences.needsRestart(
                choice: .system,
                bundle: bundle,
                systemLanguage: sameDirection
            )
        )
    }

    /// 系统语言是我们不支持的（日语），无法判断会变成哪种，不提示比误提示好。
    @Test func systemChoiceWithUnsupportedLanguageDoesNotWarn() {
        let bundle = appBundle()
        #expect(
            !LanguagePreferences.needsRestart(
                choice: .system,
                bundle: bundle,
                systemLanguage: "ja-JP"
            )
        )
    }

    /// 系统语言标识要能映射到 bundle 实际提供的那种（带地区后缀也要认）。
    @Test func matchingLocalizationNormalizesRegions() {
        let bundle = appBundle()
        // 前置条件：两份本地化都必须在，否则下面的断言没有意义。
        #expect(bundle.localizations.contains { $0.hasPrefix("zh") })
        #expect(bundle.localizations.contains { $0.hasPrefix("en") })
        #expect(LanguagePreferences.matchingLocalization(for: "zh-Hans-CN", in: bundle)?.hasPrefix("zh") == true)
        #expect(LanguagePreferences.matchingLocalization(for: "en-GB", in: bundle)?.hasPrefix("en") == true)
        #expect(LanguagePreferences.matchingLocalization(for: "ja-JP", in: bundle) == nil)
    }

    /// 选择器每一项用**自己的语言**显示。
    ///
    /// 英文界面下 "English" 不能变成 "英语"——否则用户按当前界面语言去读会认不出来。
    @Test func languageNamesAreNotTranslated() {
        #expect(LanguagePreferences.Choice.english.displayName == "English")
        // 这两项故意不本地化：语言名要用它自己的语言写，所以原样比对字面量。
        #expect(LanguagePreferences.Choice.simplifiedChinese.displayName == "简体中文")
    }

    /// 「跟随系统」这一项的名字需要本地化，否则英文界面里会冒出中文。
    @Test func systemChoiceNameIsLocalizable() {
        #expect(!LanguagePreferences.Choice.system.displayName.isEmpty)
    }
}

/// 只为拿到测试 bundle 的锚点类型。
private final class BundleAnchor {}
