import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 缩略图生成：从 PNG 数据直接降采样，避免先把原图完整解码到内存。
nonisolated enum ThumbnailGenerator {
    /// 从原图 PNG 数据生成 512 px 长边、白底 sRGB JPEG，避免列表加载原图。
    static func jpegData(
        fromPNG data: Data,
        maxPixelSize: Int = 512,
        quality: Double = 0.8
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CaptureError.encodingFailed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw CaptureError.encodingFailed
        }

        let flattened = try flattenedOnWhite(thumbnail)
        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CaptureError.encodingFailed
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, flattened, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.encodingFailed
        }
        return output as Data
    }

    /// 白底拍平：截图可能带透明区域，JPEG 不支持 alpha，不铺白底会变黑。
    private static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw CaptureError.encodingFailed
        }

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return flattened
    }
}
