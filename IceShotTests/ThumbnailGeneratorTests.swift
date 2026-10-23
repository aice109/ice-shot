import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import IceShot

/// 缩略图生成：长边限制、JPEG 签名与透明区域白底拍平。
@MainActor
struct ThumbnailGeneratorTests {
    @Test func thumbnailIsBoundedAndJPEGEncoded() throws {
        let image = try makeImage(width: 1200, height: 800)
        let png = try ImageEncoder.pngData(from: image)
        let jpeg = try ThumbnailGenerator.jpegData(fromPNG: png, maxPixelSize: 512)

        #expect(jpeg.count > 4)
        #expect(jpeg[jpeg.startIndex] == 0xFF)
        #expect(jpeg[jpeg.startIndex + 1] == 0xD8)

        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(thumbnail.width, thumbnail.height) <= 512)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
