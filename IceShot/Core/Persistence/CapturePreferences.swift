import Foundation

/// 延时截图的偏好。
///
/// 原来菜单里有 12 条「模式 × 秒数」组合（区域 / 窗口 / 全屏 / 全部显示器 × 3 / 5 / 10 秒），
/// 是菜单里最长的一段噪音。现在菜单只留一个「延时截图」，秒数在这里配一次：
/// 菜单执行的是**区域截图 + 配置的秒数**——需要延时截窗口或全屏时，先用快捷键起对应模式。
///
/// 只提供 3 / 5 / 10 三档：秒数过短来不及摆姿势，过长又不知道还要等多久。
enum CapturePreferences {
    /// `UserDefaults` 中延时秒数的 key。
    static let countdownSecondsKey = "countdownSeconds"
    /// 可选档位。菜单与设置都以这一份为准，避免两处写死不同数字。
    static let countdownOptions = [3, 5, 10]
    /// 默认秒数：3 秒足够放下一个窗口，也比 5 秒少等一轮。
    static let defaultCountdownSeconds = 3

    /// 读取延时秒数。存进来的值不在可选档位里时退回默认，避免设置被手改成怪数字。
    static func countdownSeconds(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: countdownSecondsKey)
        guard stored > 0, countdownOptions.contains(stored) else {
            return defaultCountdownSeconds
        }
        return stored
    }
}
