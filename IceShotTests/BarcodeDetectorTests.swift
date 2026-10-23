import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import IceShot

/// 条码检测：用 CoreImage 现场生成二维码，验证 Vision 真的能读出内容。
/// 这条用例同时是「二维码功能是否还在」的回归保护。
@MainActor
struct BarcodeDetectorTests {
    @Test func detectsQRCodePayload() async throws {
        let payload = "https://example.com/iceshot?code=42"
        let image = try makeQRImage(payload)
        let codes = await BarcodeDetector.detect(in: image)

        #expect(codes.count == 1)
        let code = try #require(codes.first)
        #expect(code.payload == payload)
        #expect(code.isQRCode)
        #expect(code.kindLabel == "二维码")
        // 归一化矩形应落在 0…1 内，且是左上原点坐标。
        #expect(code.normalizedRect.minX >= 0 && code.normalizedRect.maxX <= 1)
        #expect(code.normalizedRect.minY >= 0 && code.normalizedRect.maxY <= 1)
    }

    @Test func blankImageHasNoBarcode() async throws {
        let image = try makeBlankImage()
        let codes = await BarcodeDetector.detect(in: image)
        #expect(codes.isEmpty)
    }

    @Test func qrOnWhiteBackgroundIsStillDetected() async throws {
        // 截屏里的二维码通常带留白与其它内容，这里模拟白底大图。
        let payload = "IceShot-二维码验收"
        let qr = try makeQRImage(payload, scale: 8)
        let composed = try compose(qr: qr, canvas: CGSize(width: 700, height: 500))
        let codes = await BarcodeDetector.detect(in: composed)
        #expect(codes.contains { $0.payload == payload })
    }

    // MARK: - 辅助

    private func makeQRImage(_ payload: String, scale: CGFloat = 12) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        let output = try #require(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        return try #require(context.createCGImage(output, from: output.extent))
    }

    private func compose(qr: CGImage, canvas: CGSize) throws -> CGImage {
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.encodingFailed
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: canvas))
        context.interpolationQuality = .none
        context.draw(
            qr,
            in: CGRect(
                x: (canvas.width - CGFloat(qr.width)) / 2,
                y: (canvas.height - CGFloat(qr.height)) / 2,
                width: CGFloat(qr.width),
                height: CGFloat(qr.height)
            )
        )
        return try #require(context.makeImage())
    }

    private func makeBlankImage() throws -> CGImage {
        let context = CGContext(
            data: nil,
            width: 200,
            height: 120,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { throw CaptureError.encodingFailed }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        return try #require(context.makeImage())
    }
}
