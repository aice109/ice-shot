import Foundation

/// 界面语言偏好。
///
/// macOS 在**进程启动时**读取 `AppleLanguages` 并据此解析 `.lproj`，
/// 运行时改写 `UserDefaults` 不会让已加载的字符串表失效。
/// 所以这里的定位很明确：**只负责写入偏好与判断是否需要重启**，
/// 不做运行时热切换——那需要替换 `Bundle` 子类，而系统菜单（File / Edit）仍会跟随系统语言，
/// 结果是中英混杂，比不切更糟。
///
/// ## 为什么另存一个 `uiLanguageChoiceKey`
///
/// 不能靠「`AppleLanguages` 存在与否」判断用户选了什么：
/// `UserDefaults.standard` 会**回落到全局域**，而全局域里本来就有系统写入的
/// `AppleLanguages`（比如 `zh-Hans-CN`）。于是「跟随系统」和「显式选中文」
/// 在 `AppleLanguages` 上看起来一模一样，删掉应用域的键也照样读得到系统值。
///
/// 所以这里用自己的一把钥匙记「用户选了什么」，`AppleLanguages` 只作为**写入通道**：
/// - 选择 `.system` → 删掉 `AppleLanguages`，让 macOS 用它自己的偏好；
/// - 选择具体语言 → 写 `AppleLanguages`，同时记下选择。
enum LanguagePreferences {
    /// 系统解析 `.lproj` 用的键。我们只写不据此做判断。
    static let appleLanguagesKey = "AppleLanguages"
    /// 用户在本应用设置里的显式选择。缺失 = 跟随系统。
    static let uiLanguageChoiceKey = "uiLanguageChoice"

    /// 用户在设置里能选的各项。
    enum Choice: String, CaseIterable, Identifiable, Sendable {
        /// 跟随系统（默认）：不写 `AppleLanguages`，交给 macOS 决定。
        case system
        /// 简体中文。
        case simplifiedChinese = "zh-Hans"
        /// 英文。
        case english = "en"

        var id: String { rawValue }

        /// 选项自身的名字。**具体语言故意不走本地化**——语言选择器里每一项都要用
        /// 它自己的语言显示（`English` 永远是 "English"），否则英文界面下
        /// 用户会看到 "Simplified Chinese"、中文界面下看到「英语」，反而认不出来。
        var displayName: String {
            switch self {
            case .system:
                // 「跟随系统」需要一个可读的名字，这一项跟随界面语言才有意义。
                return String(localized: "跟随系统")
            case .simplifiedChinese:
                return "简体中文"
            case .english:
                return "English"
            }
        }
    }

    /// 读出用户的选择。没记过、或记了不认识的值 → 跟随系统。
    static func currentChoice(from defaults: UserDefaults = .standard) -> Choice {
        guard let raw = defaults.string(forKey: uiLanguageChoiceKey),
              let choice = Choice(rawValue: raw) else {
            return .system
        }
        return choice
    }

    /// 写入选择。`.system` 会删掉 `AppleLanguages`，把语言决定权交还 macOS。
    static func apply(
        _ choice: Choice,
        to defaults: UserDefaults = .standard
    ) {
        switch choice {
        case .system:
            defaults.removeObject(forKey: uiLanguageChoiceKey)
            defaults.removeObject(forKey: appleLanguagesKey)
        case .simplifiedChinese, .english:
            defaults.set(choice.rawValue, forKey: uiLanguageChoiceKey)
            defaults.set([choice.rawValue], forKey: appleLanguagesKey)
        }
        // 立即落盘：用户改完通常会马上重启，不能让重启进程读到旧值。
        defaults.synchronize()
    }

    /// 应用本次启动实际生效的语言（`zh-Hans` / `en` / …）。
    ///
    /// 读的是 bundle 已解析出的偏好，而不是 `AppleLanguages` 的当前值：
    /// 刚写入、尚未重启时两者本来就不同，而这正是要检测的情况。
    static func activeLanguageCode(bundle: Bundle = .main) -> String? {
        bundle.preferredLocalizations.first
    }

    /// 当前偏好生效后，界面语言是否与之一致。不一致说明需要重启。
    static func needsRestart(
        choice: Choice,
        bundle: Bundle = .main
    ) -> Bool {
        guard let active = activeLanguageCode(bundle: bundle) else { return false }
        switch choice {
        case .system:
            // 跟随系统时无从判断用户期望什么，不提示重启。
            return false
        case .simplifiedChinese:
            return !active.hasPrefix("zh")
        case .english:
            return !active.hasPrefix("en")
        }
    }
}
