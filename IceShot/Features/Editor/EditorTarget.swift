import Foundation

/// 这次编辑的「来源」：能不能删、删的是哪条记录，全由它决定。
///
/// 编辑器的「删除」是**把这张截图从历史库彻底删除**，而不是丢弃本次编辑。
/// 因此只有**从历史库打开的**编辑器才有删除入口：截完 / 长截图刚进编辑器的图
/// 记录还在异步写入，此时删会和历史写入抢时序，而且用户多半想的是「重截」而不是「删历史」。
///
/// 收藏的图也不允许删：历史清理本就豁免收藏，两者语义必须一致，否则用户会疑惑
/// 「为什么清理不动它，编辑器里却能删掉」。
///
/// 做成显式枚举而不是「可选 ID + 几个 Bool」：后者能表达出
/// 「有 ID 但不允许删」这种半状态，而这个状态在界面上没有对应表现。
enum EditorTarget: Equatable, Sendable {
    /// 截图 / 长截图直接进编辑器：没有删除入口。
    case standalone
    /// 从历史库打开：可以删除，但要先确认；收藏的图不允许删。
    case history(recordID: UUID, isFavorite: Bool)

    /// 是否显示「删除」按钮。收藏的图按钮可见但禁用，让用户知道原因，所以这里只看来源。
    var showsDelete: Bool {
        switch self {
        case .standalone: return false
        case .history: return true
        }
    }

    /// 是否真的允许删。收藏的图会被 `LibraryView` / 详情页同样拒绝，不是编辑器独有的规矩。
    var allowsDelete: Bool {
        switch self {
        case .standalone:
            return false
        case .history(_, let isFavorite):
            return !isFavorite
        }
    }

    /// 关联的历史记录，`nil` 表示这张图不在历史库里。
    var recordID: UUID? {
        switch self {
        case .standalone: return nil
        case .history(let recordID, _): return recordID
        }
    }

    /// 按钮与菜单上的提示文案；禁用时把原因写清楚，不留「为什么点不动」。
    var deleteHelp: String {
        switch self {
        case .standalone:
            return String(localized: "从历史库删除这张截图")
        case .history(_, let isFavorite) where isFavorite:
            return String(localized: "已收藏的截图不会被自动清理，请先取消收藏再删除")
        case .history:
            return String(localized: "从历史库删除这张截图（⌘⌫）")
        }
    }
}
