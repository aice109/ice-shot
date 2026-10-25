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

    /// 系统偏好（用户没给本应用单独指定语言时）会解析出哪种语言。
    ///
    /// 用 `Locale.preferredLanguages` 而不是 `Bundle.main`：
    /// `Bundle.main.preferredLocalizations` 反映的是**本进程启动时**的解析结果，
    /// 而这里要问的是「如果现在重启、把决定权交还系统，会变成什么」。
    static func systemPreferredLanguageCode() -> String? {
        Locale.preferredLanguages.first
    }

    /// 当前偏好生效后，界面语言是否与之一致。不一致说明需要重启。
    ///
    /// 三个分支都要能判出「不一致」——尤其是 `.system`：
    /// 用户从「English」切回「跟随系统」时，若系统是中文，
    /// 不重启就仍然是英文界面。早期版本这里直接 `return false`，
    /// 导致切回跟随系统后毫无反应也没提示。
    static func needsRestart(
        choice: Choice,
        bundle: Bundle = .main,
        systemLanguage: String? = systemPreferredLanguageCode()
    ) -> Bool {
        guard let active = activeLanguageCode(bundle: bundle) else { return false }

        switch choice {
        case .system:
            // 交还系统后应该跑哪种语言：系统偏好里本应用能提供的第一个。
            guard let systemLanguage,
                  let expected = matchingLocalization(for: systemLanguage, in: bundle)
            else {
                // 系统偏好信息拿不到：无法判断，不提示比误提示好。
                return false
            }
            return !active.hasPrefix(expected)
        case .simplifiedChinese:
            return !active.hasPrefix("zh")
        case .english:
            return !active.hasPrefix("en")
        }
    }

    /// 把系统语言标识（如 `zh-Hans-CN`）映射到本 bundle 实际提供的那一种（如 `zh-Hans`）。
    ///
    /// 手写前缀匹配而不是用 `Bundle.preferredLocalizations(from:forPreferences:)`：
    /// 前者对不支持的语种返回 `nil`（可以被调用方当成「无法判断」），
    /// 而后者会给一个默认值，反而会把「系统是日语、我们只有中英」
    /// 误判成需要重启。
    static func matchingLocalization(
        for languageCode: String,
        in bundle: Bundle = .main
    ) -> String? {
        let available = bundle.localizations
        if languageCode.hasPrefix("zh") {
            return available.first { $0.hasPrefix("zh") }
        }
        if languageCode.hasPrefix("en") {
            return available.first { $0.hasPrefix("en") }
        }
        return nil
    }
}
