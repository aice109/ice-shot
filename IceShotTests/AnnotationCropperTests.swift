import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 裁剪重映射：坐标都是原图像素、左上原点；裁剪后标注平移并裁掉越界部分。
@MainActor
struct AnnotationCropperTests {
    private let style = AnnotationStyle(color: .defaultRed, lineWidth: 4, opacity: 1)

    // MARK: - 矩形 / 椭圆

    @Test func fullImageCropKeepsCoordinates() {
        let annotation = makeAnnotation(.rectangle, start: (10, 20), end: (50, 60))
        let result = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(result == [annotation])
    }

    @Test func shapeIsShiftedByCropOrigin() throws {
        let annotation = makeAnnotation(.ellipse, start: (30, 40), end: (70, 80))
        let result = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 20, y: 30, width: 60, height: 60)
        )
        let shifted = try #require(result.first)
        #expect(shifted.start == CGPoint(x: 10, y: 10))
        #expect(shifted.end == CGPoint(x: 50, y: 50))
    }

    @Test func shapeIsClampedToCropBounds() throws {
        let annotation = makeAnnotation(.rectangle, start: (10, 10), end: (90, 90))
        let result = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 40, y: 40, width: 40, height: 40)
        )
        let clamped = try #require(result.first)
        #expect(clamped.start == CGPoint(x: 0, y: 0))
        #expect(clamped.end == CGPoint(x: 40, y: 40))
    }

    @Test func shapeOutsideIsDropped() {
        let annotation = makeAnnotation(.rectangle, start: (0, 0), end: (10, 10))
        let result = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 40, y: 40, width: 40, height: 40)
        )
        #expect(result.isEmpty)
    }

    // MARK: - 直线 / 文字

    @Test func lineIsClampedWhenOneEndIsOutside() throws {
        let annotation = makeAnnotation(.arrow, start: (10, 50), end: (200, 50))
        let result = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let clamped = try #require(result.first)
        #expect(clamped.start == CGPoint(x: 10, y: 50))
        #expect(clamped.end == CGPoint(x: 100, y: 50))
    }

    @Test func textKeepsOnlyInsideAnchor() {
        let inside = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: 50, y: 50),
            text: "保留",
            style: style
        )
        let outside = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 5, y: 50),
            end: CGPoint(x: 5, y: 50),
            text: "丢弃",
            style: style
        )
        let result = AnnotationCropper.remap(
            [inside, outside],
            croppingTo: CGRect(x: 20, y: 20, width: 60, height: 60)
        )
        #expect(result.count == 1)
        #expect(result.first?.text == "保留")
        #expect(result.first?.start == CGPoint(x: 30, y: 30))
    }

    // MARK: - 笔迹

    @Test func strokeKeepsLongestVisibleRun() throws {
        let annotation = EditorAnnotation(
            kind: .freehand,
            start: CGPoint(x: 0, y: 5),
            end: CGPoint(x: 0, y: 5),
            points: [
                // 框内一段（3 点）
                CGPoint(x: 30, y: 30), CGPoint(x: 40, y: 35), CGPoint(x: 50, y: 40),
                // 框外断开
                CGPoint(x: 10, y: 30),
                // 框内更短的一段（2 点）
                CGPoint(x: 70, y: 70), CGPoint(x: 80, y: 75),
            ],
            style: style
        )
        let result = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 20, y: 20, width: 70, height: 70)
        )
        let kept = try #require(result.first)
        #expect(kept.points.count == 3)
        #expect(kept.points.first == CGPoint(x: 10, y: 10))
        #expect(kept.points.last == CGPoint(x: 30, y: 20))
        #expect(kept.start == kept.points.first)
        #expect(kept.end == kept.points.last)
    }

    @Test func strokeWithSingleVisiblePointIsDropped() {
        let annotation = EditorAnnotation(
            kind: .pixelate,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: 0),
            points: [CGPoint(x: 50, y: 50), CGPoint(x: 10, y: 10)],
            style: style
        )
        let result = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 40, y: 40, width: 40, height: 40)
        )
        #expect(result.isEmpty)
    }

    // MARK: - 裁剪框合法化

    @Test func normalizedRectRoundsAndClamps() {
        let rect = AnnotationCropper.normalizedRect(
            CGRect(x: -5.4, y: 12.6, width: 60.2, height: 200),
            imageSize: CGSize(width: 100, height: 100)
        )
        #expect(rect == CGRect(x: 0, y: 13, width: 55, height: 87))
    }

    @Test func normalizedRectRejectsDegenerateInput() {
        #expect(AnnotationCropper.normalizedRect(
            CGRect(x: 0, y: 0, width: 0.4, height: 10),
            imageSize: CGSize(width: 100, height: 100)
        ) == nil)
        #expect(AnnotationCropper.normalizedRect(
            CGRect(x: 200, y: 200, width: 20, height: 20),
            imageSize: CGSize(width: 100, height: 100)
        ) == nil)
    }

    // MARK: - 模型

    @Test func applyCropResizesImageAndRemapsAnnotations() throws {
        let model = EditorModel(image: try makeImage(width: 120, height: 80), title: "Test")
        model.attachUndoManager(UndoManager())
        model.add(makeAnnotation(.rectangle, start: (20, 10), end: (60, 40)))

        model.setTool(.crop)
        #expect(model.cropRect == CGRect(x: 0, y: 0, width: 120, height: 80))

        model.updateCropRect(CGRect(x: 10, y: 5, width: 80, height: 50))
        #expect(model.applyCrop())

        #expect(model.image.width == 80)
        #expect(model.image.height == 50)
        #expect(model.cropRect == nil)
        #expect(model.tool == .select)
        #expect(model.annotations.first?.start == CGPoint(x: 10, y: 5))
        #expect(model.annotations.first?.end == CGPoint(x: 50, y: 35))
        #expect(model.canUndo)
    }

    @Test func undoRestoresImageAndAnnotationsTogether() throws {
        let model = EditorModel(image: try makeImage(width: 120, height: 80), title: "Test")
        model.attachUndoManager(UndoManager())
        let annotation = makeAnnotation(.rectangle, start: (20, 10), end: (60, 40))
        model.add(annotation)

        model.setTool(.crop)
        model.updateCropRect(CGRect(x: 10, y: 5, width: 80, height: 50))
        #expect(model.applyCrop())

        model.undo()
        // 图像与标注必须一起回来，否则坐标会与旧尺寸错位。
        #expect(model.image.width == 120)
        #expect(model.image.height == 80)
        #expect(model.annotations == [annotation])

        model.redo()
        #expect(model.image.width == 80)
        #expect(model.annotations.first?.start == CGPoint(x: 10, y: 5))
    }

    @Test func unchangedCropRangeProducesNoUndoEntry() throws {
        let model = EditorModel(image: try makeImage(width: 60, height: 40), title: "Test")
        model.attachUndoManager(UndoManager())
        model.setTool(.crop)

        #expect(!model.applyCrop())
        #expect(model.image.width == 60)
        #expect(!model.canUndo)
        #expect(model.tool == .select)
        #expect(model.statusMessage == "裁剪范围未变化")
    }

    /// 整幅初始态下框内拖动必须是「拉新框」：否则拖动只是平移一个整幅大小的框，看起来像裁剪没反应。
    @Test func cropRectIsFullFrameOnlyBeforeAdjusting() throws {
        let model = EditorModel(image: try makeImage(width: 60, height: 40), title: "Test")
        model.setTool(.crop)
        #expect(model.isCropRectFullFrame)

        model.updateCropRect(CGRect(x: 10, y: 10, width: 20, height: 10))
        #expect(!model.isCropRectFullFrame)

        model.cancelCrop()
        #expect(model.isCropRectFullFrame)
    }

    @Test func cancelCropKeepsImage() throws {        let model = EditorModel(image: try makeImage(width: 60, height: 40), title: "Test")
        model.setTool(.crop)
        model.updateCropRect(CGRect(x: 10, y: 10, width: 20, height: 10))
        model.cancelCrop()

        #expect(model.image.width == 60)
        #expect(model.cropRect == nil)
        #expect(model.tool == .select)
        #expect(!model.canUndo)
    }

    // MARK: - 辅助

    private func makeAnnotation(
        _ kind: AnnotationKind,
        start: (CGFloat, CGFloat),
        end: (CGFloat, CGFloat)
    ) -> EditorAnnotation {
        EditorAnnotation(
            kind: kind,
            start: CGPoint(x: start.0, y: start.1),
            end: CGPoint(x: end.0, y: end.1),
            style: style
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let provider = CGDataProvider(
            data: Data(count: width * height * 4) as CFData
        )
        guard let provider,
              let image = CGImage(
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
