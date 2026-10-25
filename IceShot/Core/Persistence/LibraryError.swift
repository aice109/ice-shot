import Foundation

/// 历史库的结构化错误。
///
/// 每个 case 对应一个明确的用户可理解原因，UI 直接展示 `errorDescription`，
/// 不再临时拼接「操作失败」之类的笼统文案。
enum LibraryError: Error, LocalizedError {
    case storageUnavailable
    case fileWriteFailed(code: Int)
    case fileDeleteFailed(code: Int)
    case thumbnailFailed
    case recordSaveFailed

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return String(localized: "无法打开历史记录存储。请检查磁盘空间与应用沙盒权限。")
        case .fileWriteFailed:
            return String(localized: "截图写入历史记录失败。请检查磁盘空间。")
        case .fileDeleteFailed:
            return String(localized: "删除历史记录文件失败。请稍后重试。")
        case .thumbnailFailed:
            return String(localized: "生成截图缩略图失败。")
        case .recordSaveFailed:
            return String(localized: "保存历史记录元数据失败。")
        }
    }
}
