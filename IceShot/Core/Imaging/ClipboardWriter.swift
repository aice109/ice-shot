import AppKit
import CoreGraphics

/// 把截图写入系统剪贴板。
///
/// 同时写入 PNG 与 TIFF：PNG 保留无损画质、体积小，TIFF 兼容只接受位图的旧应用。
@MainActor
struct ClipboardWriter {
    func copy(_ image: CGImage) throws {
        let pngData = try ImageEncoder.pngData(from: image)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let tiffData = bitmap.representation(using: .tiff, properties: [:]) else {
            throw CaptureError.encodingFailed
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setData(pngData, forType: .png)
        _ = pasteboard.setData(tiffData, forType: .tiff)
    }
}
