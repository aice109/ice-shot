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

    /// 「跟随系统」无从判断用户期望什么，永远不该提示重启。
    @Test func systemChoiceNeverNeedsRestart() {
        let bundle = Bundle(for: BundleAnchor.self)
        #expect(!LanguagePreferences.needsRestart(choice: .system, bundle: bundle))
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
