import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PNG 编码工具。
///
/// 标记为 `nonisolated`：大图编码可能耗时，允许调用方从后台任务执行，
/// 避免占用 `@MainActor` 阻塞界面。
nonisolated enum ImageEncoder {
    static func pngData(from image: CGImage) throws -> Data {
        guard let data = CFDataCreateMutable(nil, 0) else {
            throw CaptureError.encodingFailed
        }
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptureError.encodingFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.encodingFailed
        }
        return data as Data
    }
}
