import CoreGraphics

/// 图像的 90° 旋转与镜像翻转。
///
/// 只用整数倍 90° 与镜像，不做任意角度重采样：旋转 4 次、翻转 2 次都能像素级还原，
/// 不会因为插值产生模糊。
enum ImageTransformer {
    /// 顺时针 / 逆时针旋转 90°；尺寸互换为 `height × width`。
    static func rotated(_ image: CGImage, clockwise: Bool) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw CaptureError.encodingFailed }

        // 旋转后画布是 (height × width)。
        guard let context = makeContext(width: height, height: width) else {
            throw CaptureError.encodingFailed
        }
        // CGContext 是左下原点、y 向上的坐标系，这里把左上原点推导的映射换算过来：
        // 顺时针 (x, y) → (H - y, x)，逆时针 (x, y) → (y, W - x)。
        if clockwise {
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
        }
        draw(image, in: context)
        guard let output = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return output
    }

    /// 水平（左右镜像）/ 垂直（上下镜像）翻转；尺寸不变。
    static func flipped(_ image: CGImage, horizontal: Bool) throws -> CGImage {
        guard let context = makeContext(width: image.width, height: image.height) else {
            throw CaptureError.encodingFailed
        }
        if horizontal {
            context.translateBy(x: CGFloat(image.width), y: 0)
            context.scaleBy(x: -1, y: 1)
        } else {
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
        }
        draw(image, in: context)
        guard let output = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return output
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func draw(_ image: CGImage, in context: CGContext) {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: rect)
    }
}
