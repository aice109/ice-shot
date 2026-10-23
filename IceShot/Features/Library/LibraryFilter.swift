import Foundation

/// 历史列表的筛选维度（全部 / 收藏 / 今天 / 最近 7 天）。
///
/// 只负责时间与收藏判断；搜索框的标签 / 来源文本过滤在 `LibraryView` 里叠加，
/// 两者互不影响，切换筛选不会清空搜索词。
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case today
    case week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        case .today: return "今天"
        case .week: return "最近 7 天"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "photo.stack"
        case .favorites: return "heart"
        case .today: return "sun.max"
        case .week: return "calendar"
        }
    }

    /// 判断记录是否属于当前筛选。`now` 可注入，便于测试固定时间边界。
    func includes(_ record: ScreenshotRecord, now: Date = Date()) -> Bool {
        switch self {
        case .all:
            return true
        case .favorites:
            return record.isFavorite
        case .today:
            return Calendar.current.isDate(record.createdAt, inSameDayAs: now)
        case .week:
            guard let cutoff = Calendar.current.date(
                byAdding: .day,
                value: -7,
                to: now
            ) else {
                return true
            }
            return record.createdAt >= cutoff
        }
    }
}
