import CoreGraphics

enum ImageCropper {
    /// 按图像左上原点的像素矩形裁切。
    ///
    /// 该约定已用 2×2 合成图验证：`CGImage.cropping(to:)` 的 (0,0) 对应图像左上角。
    static func crop(_ image: CGImage, to pixelRect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = pixelRect.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            throw CaptureError.invalidSelection
        }
        guard let cropped = image.cropping(to: rect) else {
            throw CaptureError.invalidSelection
        }
        return cropped
    }
}
