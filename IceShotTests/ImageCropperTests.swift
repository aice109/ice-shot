import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 裁剪约定：像素矩形以图像左上角为原点，越界时裁剪到图像范围内。
@MainActor
struct ImageCropperTests {
    @Test func cropUsesTopLeftOrigin() throws {
        let image = try makeTwoByTwoImage()

        let topLeft = try ImageCropper.crop(
            image,
            to: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let bottomLeft = try ImageCropper.crop(
            image,
            to: CGRect(x: 0, y: 1, width: 1, height: 1)
        )

        #expect(try pixel(in: topLeft) == Pixel(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(try pixel(in: bottomLeft) == Pixel(red: 0, green: 0, blue: 255, alpha: 255))
    }

    @Test func cropClampsToImageBounds() throws {
        let image = try makeTwoByTwoImage()
        let crop = try ImageCropper.crop(
            image,
            to: CGRect(x: 1, y: 1, width: 10, height: 10)
        )
        #expect(crop.width == 1)
        #expect(crop.height == 1)
    }

    @Test func invalidSelectionThrows() throws {
        let image = try makeTwoByTwoImage()
        #expect(throws: CaptureError.self) {
            try ImageCropper.crop(image, to: CGRect(x: 10, y: 10, width: 1, height: 1))
        }
    }

    private func makeTwoByTwoImage() throws -> CGImage {
        let width = 2
        let height = 2
        let pixels: [(UInt8, UInt8, UInt8, UInt8)] = [
            (255, 0, 0, 255), (0, 255, 0, 255),
            (0, 0, 255, 255), (255, 255, 255, 255),
        ]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, pixel) in pixels.enumerated() {
            bytes[index * 4 + 0] = pixel.0
            bytes[index * 4 + 1] = pixel.1
            bytes[index * 4 + 2] = pixel.2
            bytes[index * 4 + 3] = pixel.3
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw CaptureError.encodingFailed
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
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

    private func pixel(in image: CGImage) throws -> Pixel {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            throw CaptureError.encodingFailed
        }
        let bytesPerPixel = image.bitsPerPixel / 8
        return Pixel(
            red: pointer[0],
            green: pointer[bytesPerPixel == 4 ? 1 : 0],
            blue: pointer[bytesPerPixel == 4 ? 2 : 0],
            alpha: pointer[bytesPerPixel == 4 ? 3 : 0]
        )
    }
}

private struct Pixel: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}
