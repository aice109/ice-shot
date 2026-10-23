import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 取字模式的状态机：与裁剪 / 工具切换互斥，退出时清提示。
/// Live Text 本身由系统负责，这里只测我们这层的状态变化。
@MainActor
struct LiveTextModeTests {
    @Test func enteringTextPickingClearsSelection() throws {
        let model = EditorModel(image: try makeImage(), title: "Test")
        let annotation = EditorAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 5, y: 5),
            end: CGPoint(x: 35, y: 15),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 4, opacity: 1)
        )
        model.add(annotation)
        model.select(annotation.id)

        model.setTextPicking(true)
        #expect(model.isTextPicking)
        #expect(model.selectedID == nil)
        #expect(model.statusMessage?.contains("⌘C") == true)
    }

    @Test func enteringTextPickingCancelsCrop() throws {
        let model = EditorModel(image: try makeImage(), title: "Test")
        model.setTool(.crop)
        #expect(model.cropRect != nil)

        model.setTextPicking(true)
        #expect(model.isTextPicking)
        #expect(!model.isCropping)
        #expect(model.cropRect == nil)
        #expect(model.tool == .select)
    }

    @Test func choosingToolExitsTextPicking() throws {
        let model = EditorModel(image: try makeImage(), title: "Test")
        model.setTextPicking(true)

        model.setTool(.rectangle)
        #expect(!model.isTextPicking)
        // 退出取字后不应该残留取字提示。
        #expect(model.statusMessage == nil)
    }

    @Test func exitingTextPickingClearsHint() throws {
        let model = EditorModel(image: try makeImage(), title: "Test")
        model.setTextPicking(true)
        model.setTextPicking(false)
        #expect(!model.isTextPicking)
        #expect(model.statusMessage == nil)
        // 退出后仍停留在「选择」工具，可以直接继续画 / 选。
        #expect(model.tool == .select)
    }

    @Test func aspectFitRectCentersImage() {
        let rect = ImageDisplayGeometry.aspectFitRect(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 400, height: 400)
        )
        #expect(rect == CGRect(x: 0, y: 100, width: 400, height: 200))

        let empty = ImageDisplayGeometry.aspectFitRect(
            imageSize: .zero,
            in: CGSize(width: 400, height: 400)
        )
        #expect(empty == .zero)
    }

    private func makeImage() throws -> CGImage {
        let width = 40
        let height = 20
        guard let provider = CGDataProvider(
            data: Data(count: width * height * 4) as CFData
        ) else {
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
}
