import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

@MainActor
struct EditorModelTests {
    @Test func canvasLayoutFitsImageAndRoundTripsPoints() {
        let layout = EditorCanvasLayout(
            imageSize: CGSize(width: 400, height: 200),
            viewSize: CGSize(width: 1000, height: 600),
            padding: 20
        )
        #expect(abs(layout.imageRect.width - 960) < 0.001)
        #expect(abs(layout.imageRect.height - 480) < 0.001)
        #expect(layout.imageRect.midX == 500)
        #expect(layout.imageRect.midY == 300)

        let imagePoint = CGPoint(x: 100, y: 50)
        let roundTrip = layout.imagePoint(layout.viewPoint(imagePoint))
        #expect(abs(roundTrip.x - imagePoint.x) < 0.001)
        #expect(abs(roundTrip.y - imagePoint.y) < 0.001)
    }

    @Test func annotationHitTestAndOffset() {
        let annotation = EditorAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 110, y: 60),
            style: AnnotationStyle(
                color: .defaultRed,
                lineWidth: 3,
                opacity: 1
            )
        )
        // 矩形是**描边不填充**的：命中只算四条边，中间空白不算。
        // 这与光标规则一致（中间空白处不显示抓手）。
        #expect(annotation.hitTest(CGPoint(x: 60, y: 10)), "上边")
        #expect(annotation.hitTest(CGPoint(x: 60, y: 60)), "下边")
        #expect(annotation.hitTest(CGPoint(x: 10, y: 35)), "左边")
        #expect(annotation.hitTest(CGPoint(x: 110, y: 35)), "右边")
        #expect(!annotation.hitTest(CGPoint(x: 60, y: 35)), "中间空白不应命中")
        #expect(!annotation.hitTest(CGPoint(x: 200, y: 200)))

        let moved = annotation.offsetBy(dx: 20, dy: -5)
        #expect(moved.bounds == CGRect(x: 30, y: 5, width: 100, height: 50))
        #expect(moved.id == annotation.id)
    }

    @Test func addUndoRedoAndDelete() throws {
        let model = EditorModel(
            image: try makeImage(width: 100, height: 80),
            title: "Test"
        )
        model.attachUndoManager(UndoManager())
        let annotation = EditorAnnotation(
            kind: .ellipse,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 90, y: 70),
            style: AnnotationStyle(
                color: .defaultRed,
                lineWidth: 4,
                opacity: 1
            )
        )
        model.add(annotation)
        #expect(model.annotations.count == 1)
        // 绘制完成不自动选中，避免每画一笔都多出一圈选中框。
        #expect(model.selectedID == nil)
        #expect(model.canUndo)
        #expect(!model.canRedo)

        model.undo()
        #expect(model.annotations.isEmpty)
        #expect(model.canRedo)

        model.redo()
        #expect(model.annotations.count == 1)
        #expect(model.canUndo)
        #expect(!model.canRedo)

        model.select(annotation.id)
        model.deleteSelected()
        #expect(model.annotations.isEmpty)

        model.undo()
        #expect(model.annotations.count == 1)
    }

    @Test func rendererProducesImageAtPixelSize() throws {
        let model = EditorModel(
            image: try makeImage(width: 120, height: 90),
            title: "Test"
        )
        model.add(EditorAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 110, y: 80),
            style: AnnotationStyle(
                color: .defaultRed,
                lineWidth: 4,
                opacity: 1
            )
        ))
        let rendered = try #require(model.renderedImage())
        #expect(rendered.width == 120)
        #expect(rendered.height == 90)

        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let strokePixel = try #require(bitmap.colorAt(x: 10, y: 45))
        let centerPixel = try #require(bitmap.colorAt(x: 60, y: 45))
        #expect(strokePixel.redComponent > 0.7)
        #expect(centerPixel.redComponent > 0.9)
        #expect(centerPixel.greenComponent > 0.9)
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
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
