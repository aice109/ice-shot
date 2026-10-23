import CoreGraphics
import Foundation

/// 截图写入历史的抽象入口，由 `LibraryStore` 实现。
///
/// 用协议把「截图流程」与「持久化」隔开：捕获层只依赖这个协议，
/// 不需要知道 SwiftData 模型或沙盒文件布局。
@MainActor
protocol HistorySaving: AnyObject {
    /// 保存一批截图（全部显示器会一次传入多张）。
    /// - Parameters:
    ///   - images: 同一次截图产生的图像，顺序与显示器顺序一致。
    ///   - source: 截图来源，决定历史列表里的分类标签。
    ///   - createdAt: 统一时间戳，保证同一批记录排序稳定。
    func save(
        _ images: [CGImage],
        source: ScreenshotSource,
        createdAt: Date
    ) async throws
}
