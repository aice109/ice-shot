import AppKit
import CoreGraphics

/// 一条历史记录上的动作：列表右键菜单与详情工具栏共用同一套实现。
///
/// 只做「取图 → 交给系统」的编排，不持有状态也不缓存图像。同一条记录在列表和详情里
/// 必须给出相同结果，所以读盘 / 复制 / 另存 / 贴图的逻辑只能有一份。
///
/// 语义：历史库存的是**原图**（标注结果另存不回写），因此这里导出的都是不含标注的原图；
/// 要带标注得先进编辑器。
@MainActor
struct LibraryRecordActions {
    let library: LibraryStore
    /// 贴图板是会话级的；为 nil 时调用方不应展示「贴图」入口。
    let pins: PinBoard?

    /// 原图在沙盒里的绝对路径；文件已缺失时返回 nil。
    func originalURL(for record: ScreenshotRecord) -> URL? {
        guard let url = library.fileStore.originalURL(named: record.originalFileName),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// 复制原图到剪贴板（PNG + TIFF，与截图流程一致）。
    func copyImage(_ record: ScreenshotRecord) async throws {
        try ClipboardWriter().copy(try await originalImage(of: record))
    }

    /// 另存为 PNG；返回 false 表示用户取消。
    func saveAsPNG(_ record: ScreenshotRecord) async throws -> Bool {
        try SavePanel.savePNG(try await originalImage(of: record))
    }

    /// 贴成置顶浮窗；没有贴图板时返回 false（调用方本来就不该显示入口）。
    func pin(_ record: ScreenshotRecord) async throws -> Bool {
        guard let pins else { return false }
        _ = pins.present(image: try await originalImage(of: record))
        return true
    }

    /// 在 Finder 中定位原图；文件已缺失时返回 false。
    @discardableResult
    func revealInFinder(_ record: ScreenshotRecord) -> Bool {
        guard let url = originalURL(for: record) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    private func originalImage(of record: ScreenshotRecord) async throws -> CGImage {
        guard let image = await library.image(for: record, thumbnail: false) else {
            throw LibraryActionError.originalMissing
        }
        return image
    }
}

/// 历史记录动作的失败原因；文案直接给用户看，不拼「操作失败」这种笼统话。
enum LibraryActionError: LocalizedError {
    /// 数据库里有记录，但原图文件已被清理或丢失。
    case originalMissing

    var errorDescription: String? {
        switch self {
        case .originalMissing:
            return String(localized: "这张截图的原图已不在磁盘上，可能被清理掉了。可以删除这条记录。")
        }
    }
}
