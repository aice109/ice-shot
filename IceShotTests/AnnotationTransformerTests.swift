import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 旋转 / 翻转：坐标是原图像素、左上原点；90° 与镜像必须可逆。
@MainActor
struct AnnotationTransformerTests {
    private let style = AnnotationStyle(color: .defaultRed, lineWidth: 4, opacity: 1)
    private let imageSize = CGSize(width: 100, height: 80)

    // MARK: - 坐标映射

    @Test func clockwiseRotationMapsAdjacentPixels() throws {
        let rect = EditorAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 50, y: 60),
            style: style
        )
        let result = AnnotationTransformer.rotated(
            [rect],
            imageSize: imageSize,
            clockwise: true
        )
        let rotated = try #require(result.first)
        // (x, y) → (H - y, x)，H = 80
        #expect(rotated.start == CGPoint(x: 60, y: 10))
        #expect(rotated.end == CGPoint(x: 20, y: 50))
    }

    @Test func counterClockwiseRotationMapsAdjacentPixels() throws {
        let line = EditorAnnotation(
            kind: .arrow,
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 50, y: 60),
            style: style
        )
        let result = AnnotationTransformer.rotated(
            [line],
            imageSize: imageSize,
            clockwise: false
        )
        let rotated = try #require(result.first)
        // (x, y) → (y, W - x)，W = 100
        #expect(rotated.start == CGPoint(x: 20, y: 90))
        #expect(rotated.end == CGPoint(x: 60, y: 50))
    }

    @Test func flipsMirrorSingleAxis() {
        let rect = EditorAnnotation(
            kind: .ellipse,
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 50, y: 60),
            style: style
        )
        let horizontal = AnnotationTransformer.flipped(
            [rect],
            imageSize: imageSize,
            horizontal: true
        )
        #expect(horizontal.first?.start == CGPoint(x: 90, y: 20))
        #expect(horizontal.first?.end == CGPoint(x: 50, y: 60))

        let vertical = AnnotationTransformer.flipped(
            [rect],
            imageSize: imageSize,
            horizontal: false
        )
        #expect(vertical.first?.start == CGPoint(x: 10, y: 60))
        #expect(vertical.first?.end == CGPoint(x: 50, y: 20))
    }

    // MARK: - 可逆性

    @Test func fourClockwiseRotationsRestoreCoordinates() {
        var annotations = [
            StrokeFixture.make(kind: .freehand, style: style),
            EditorAnnotation(
                kind: .rectangle,
                start: CGPoint(x: 10, y: 20),
                end: CGPoint(x: 50, y: 60),
                style: style
            ),
        ]
        let original = annotations
        var size = imageSize
        for _ in 0..<4 {
            annotations = AnnotationTransformer.rotated(
                annotations,
                imageSize: size,
                clockwise: true
            )
            size = CGSize(width: size.height, height: size.width)
        }
        #expect(size == imageSize)
        #expect(annotations == original)
    }

    @Test func clockwiseThenCounterClockwiseRestoresCoordinates() {
        let original = [StrokeFixture.make(kind: .pixelate, style: style)]
        let rotated = AnnotationTransformer.rotated(
            original,
            imageSize: imageSize,
            clockwise: true
        )
        let restored = AnnotationTransformer.rotated(
            rotated,
            imageSize: CGSize(width: imageSize.height, height: imageSize.width),
            clockwise: false
        )
        #expect(restored == original)
    }

    @Test func flipTwiceRestoresCoordinates() {
        let original = [StrokeFixture.make(kind: .highlighter, style: style)]
        for horizontal in [true, false] {
            let flipped = AnnotationTransformer.flipped(
                original,
                imageSize: imageSize,
                horizontal: horizontal
            )
            let restored = AnnotationTransformer.flipped(
                flipped,
                imageSize: imageSize,
                horizontal: horizontal
            )
            #expect(restored == original)
        }
    }

    // MARK: - 文字

    @Test func textStaysUprightAndIsClampedInsideCanvas() throws {
        let text = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 2, y: 40),
            end: CGPoint(x: 2, y: 40),
            text: "编号",
            style: style
        )
        let result = AnnotationTransformer.rotated(
            [text],
            imageSize: imageSize,
            clockwise: true
        )
        let rotated = try #require(result.first)
        // 顺时针后 x = H - y = 40，y = 2；新画布 80 × 100。
        #expect(rotated.start.y == 2)
        // x 可能因「文字整体留在画布内」被回夹，这里以回夹后的合法位置为准。
        let width = rotated.measuredTextSize.width
        #expect(rotated.start.x == min(40, 80 - width))
        // 锚点仍被限制在新画布内（文字整体可见）。
        let size = rotated.measuredTextSize
        #expect(rotated.start.x + size.width <= 80)
        #expect(rotated.start.y + size.height <= 100)
    }

    // MARK: - 图像

    @Test func rotatingImageSwapsDimensions() throws {
        let image = try makeImage(width: 6, height: 4)
        let clockwise = try ImageTransformer.rotated(image, clockwise: true)
        #expect(clockwise.width == 4)
        #expect(clockwise.height == 6)

        let twice = try ImageTransformer.rotated(clockwise, clockwise: true)
        #expect(twice.width == 6)
        #expect(twice.height == 4)
    }

    @Test func flippingImageKeepsDimensions() throws {
        let image = try makeImage(width: 6, height: 4)
        for horizontal in [true, false] {
            let flipped = try ImageTransformer.flipped(image, horizontal: horizontal)
            #expect(flipped.width == 6)
            #expect(flipped.height == 4)
        }
    }

    // MARK: - 模型

    @Test func rotateSwapsSizeAndUndoRestores() throws {
        let model = EditorModel(image: try makeImage(width: 120, height: 80), title: "Test")
        model.attachUndoManager(UndoManager())
        let rect = EditorAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 50, y: 60),
            style: style
        )
        model.add(rect)

        #expect(model.rotate(clockwise: true))
        #expect(model.image.width == 80)
        #expect(model.image.height == 120)
        // (x, y) → (H - y, x) = (80 - 20, 10)
        #expect(model.annotations.first?.start == CGPoint(x: 60, y: 10))
        #expect(model.canUndo)

        model.undo()
        #expect(model.image.width == 120)
        #expect(model.image.height == 80)
        #expect(model.annotations == [rect])
    }

    @Test func flipIsDisabledWhileCropping() throws {
        let model = EditorModel(image: try makeImage(width: 60, height: 40), title: "Test")
        model.setTool(.crop)
        #expect(!model.flip(horizontal: true))
        #expect(!model.rotate(clockwise: true))
        #expect(model.image.width == 60)
    }

    // MARK: - 辅助

    private func makeImage(width: Int, height: Int) throws -> CGImage {
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

private enum StrokeFixture {
    static func make(kind: AnnotationKind, style: AnnotationStyle) -> EditorAnnotation {
        EditorAnnotation(
            kind: kind,
            start: CGPoint(x: 5, y: 15),
            end: CGPoint(x: 35, y: 45),
            points: [
                CGPoint(x: 5, y: 15),
                CGPoint(x: 12, y: 30),
                CGPoint(x: 35, y: 45),
            ],
            style: style
        )
    }
}
