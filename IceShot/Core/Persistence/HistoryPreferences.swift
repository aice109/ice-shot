import Foundation

/// 历史库的容量与保留策略。
///
/// 数值是有意写死的上限：截图可能很大，必须有确定的天数 / 数量 / 体积边界，
/// 避免历史库无限增长；收藏记录不受自动清理影响。
/// 设置界面只暴露「是否保存」开关，其余策略由这里统一维护。
enum HistoryPreferences {
    /// `UserDefaults` 中的开关 key；关闭后新截图不再写入历史。
    static let enabledKey = "historyEnabled"
    /// 自动清理的时间窗口（天）。
    static let retentionDays = 30
    /// 自动清理的数量上限（张）。
    static let maximumCount = 500
    /// 自动清理的体积上限（2 GB）。
    static let maximumByteSize: Int64 = 2 * 1024 * 1024 * 1024

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
