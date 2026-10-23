import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 空白帧检测：抓到的窗口图几乎没有不透明像素时要判失败，
/// 否则「通知横幅」这类 overlay 会一路产出空白截图。
@MainActor
struct BlankFrameDetectorTests {
    /// 造一张测试图：`fillRect` 为 nil 表示整张全透明，否则只画这块矩形。
    private func image(
        width: Int = 200,
        height: Int = 200,
        fillRect: CGRect? = nil,
        alpha: CGFloat = 1
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: alpha))
        if let fillRect {
            context.fill(fillRect)
        }
        return context.makeImage()!
    }

    @Test func fullyOpaqueImageIsNotBlank() {
        let opaque = image(fillRect: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(!BlankFrameDetector.isBlank(opaque))
        #expect(BlankFrameDetector.opaqueRatio(opaque) > 0.95)
    }

    @Test func fullyTransparentImageIsBlank() {
        let empty = image()
        #expect(BlankFrameDetector.isBlank(empty))
        #expect(BlankFrameDetector.opaqueRatio(empty) < 0.01)
    }

    @Test func notificationBannerShapeCountsAsBlank() {
        // 复现真实形态：整屏只有一条横幅不透明（约 1%），其余全透明。
        let banner = image(
            width: 400,
            height: 400,
            fillRect: CGRect(x: 300, y: 300, width: 90, height: 40)
        )
        let ratio = BlankFrameDetector.opaqueRatio(banner)
        #expect(ratio < 0.05)
        #expect(BlankFrameDetector.isBlank(banner))
    }

    @Test func normalWindowWithWidePaddingIsNotBlank() {
        // 真实窗口截图的留白也不会低到 5% 以下，阈值不能误杀。
        let padded = image(
            width: 400,
            height: 400,
            fillRect: CGRect(x: 0, y: 0, width: 200, height: 400)
        )
        #expect(!BlankFrameDetector.isBlank(padded))
    }

    @Test func thresholdIsInSaneRange() {
        #expect(BlankFrameDetector.minimumOpaqueRatio > 0)
        #expect(BlankFrameDetector.minimumOpaqueRatio < 0.5)
    }
}
