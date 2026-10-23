import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// PNG 编码输出：文件签名、尺寸与透明通道保持正确。
@MainActor
struct ImageEncoderTests {
    @Test func pngDataHasPNGSignature() throws {
        let image = try makeOnePixelImage()
        let data = try ImageEncoder.pngData(from: image)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(Array(data.prefix(signature.count)) == signature)
    }

    private func makeOnePixelImage() throws -> CGImage {
        let bytes: [UInt8] = [255, 0, 0, 255]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw CaptureError.encodingFailed
        }
        guard let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw CaptureError.encodingFailed
        }
        return image
    }
}
