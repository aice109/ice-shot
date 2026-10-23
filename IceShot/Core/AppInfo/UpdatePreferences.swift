import Foundation

/// 更新检查的偏好键与默认值。
///
/// 和 `HistoryPreferences` / `OCRPreferences` 保持同一形状：key 是静态常量、
/// 小写驼峰、不带前缀，方便在 `defaults read` 里一眼认出来。
///
/// 「检查节流」与「版本静默」是两件不同的事，键也分开存：
/// - `lastCheckDate` 控制**多久查一次**（每天最多一次）；
/// - `skippedVersion` 控制**查到了要不要打扰**（用户点过「稍后」的版本）。
enum UpdatePreferences {
    /// 自动检查开关；关闭后启动与打开面板都不再联网。
    static let enabledKey = "updateCheckEnabled"
    /// 上次**完成**检查的时间；失败也写，避免断网时反复重试。
    static let lastCheckDateKey = "updateLastCheckDate"
    /// 用户点过「稍后」的版本号，形如 `0.3.2`。
    static let skippedVersionKey = "updateSkippedVersion"

    /// 两次自动检查之间的最小间隔（24 小时）。
    static let checkInterval: TimeInterval = 24 * 60 * 60

    static var isEnabledByDefault: Bool { true }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? isEnabledByDefault
    }
}
