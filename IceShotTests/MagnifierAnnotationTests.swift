import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 放大镜：工具与选项、几何映射，以及「框里确实显示的是放大后的自己」。
@MainActor
struct MagnifierAnnotationTests {
    // MARK: - 工具与选项

    @Test func magnifierToolBelongsToMoreGroup() {
        // 放大镜收口进「更多」，不再独占一格。
        #expect(EditorTool.magnifier.toolGroup == .more)
        #expect(EditorTool.ToolGroup.more.members.contains(.magnifier))
        #expect(EditorTool.magnifier.shortcut == "z")
        #expect(EditorTool.magnifier.annotationKind == .magnifier)
    }

    @Test func magnifierOptionsHaveShapeAndZoomOnly() {
        let options = EditorToolOptions(tool: .magnifier)
        #expect(options.isPresented)
        #expect(options.showsMagnifier)
        #expect(options.showsColor == false)
        #expect(options.widthRole == nil)
        #expect(options.showsRedaction == false)
        #expect(options.showsSpotlight == false)
        #expect(EditorToolOptions.magnifier.showsMagnifier)
    }

    @Test func zoomClampsToSupportedLevels() {
        var style = MagnifierStyle()
        #expect(style.shape == .ellipse)
        #expect(style.zoom == MagnifierStyle.defaultZoom)
        style.zoom = 99
        #expect(style.clampedZoom == MagnifierStyle.zoomLevels.last)
        style.zoom = 0.1
        #expect(style.clampedZoom == MagnifierStyle.zoomLevels.first)
    }

    @Test func activeStyleCarriesMagnifierSettings() throws {
        let model = EditorModel(image: try makeImage(width: 120, height: 60), title: "Test")
        model.setTool(.magnifier)
        model.setMagnifierShape(.rectangle)
        model.setMagnifierZoom(3)
        let style = model.activeStyle
        #expect(style.magnifier?.shape == .rectangle)
        #expect(style.magnifier?.zoom == 3)
        #expect(style.lineWidth == 1)
    }

    @Test func changingZoomUpdatesSelectedMagnifierAndUndoRestores() throws {
        let model = EditorModel(image: try makeImage(width: 120, height: 60), title: "Test")
        model.attachUndoManager(UndoManager())
        model.setTool(.magnifier)
        model.add(EditorAnnotation(
            kind: .magnifier,
            start: CGPoint(x: 20, y: 10),
            end: CGPoint(x: 80, y: 50),
            style: model.activeStyle
        ))
        model.select(try #require(model.annotations.first).id)

        model.setMagnifierZoom(3)
        #expect(model.annotations.first?.magnifierStyle.zoom == 3)

        model.undo()
        #expect(model.annotations.first?.magnifierStyle.zoom == MagnifierStyle.defaultZoom)
    }

    // MARK: - 几何

    @Test func hitAreaIsTheFrame() {
        let annotation = EditorAnnotation(
            kind: .magnifier,
            start: CGPoint(x: 20, y: 20),
            end: CGPoint(x: 80, y: 60),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1)
        )
        #expect(annotation.bounds == CGRect(x: 20, y: 20, width: 60, height: 40))
        #expect(annotation.hitTest(CGPoint(x: 50, y: 40)))
        #expect(annotation.hitTest(CGPoint(x: 5, y: 5)) == false)
    }

    @Test func croppingRemapsTheFrame() throws {
        let annotation = EditorAnnotation(
            kind: .magnifier,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 90, y: 60),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1)
        )
        let crop = CGRect(x: 40, y: 20, width: 40, height: 30)
        let remapped = try #require(AnnotationCropper.remap(annotation, croppingTo: crop))
        #expect(remapped.bounds == CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    // MARK: - 导出一致性

    /// 白底 + 一条位于 x=48..52 的黑竖条。
    ///
    /// 放大镜框 (30,10)–(90,50)、倍数 2× 时，这条竖条会被推到 36..44：
    /// 于是「框内 x=40 是黑、框外同位置是白」才能证明框里真的是放大后的内容，
    /// 而不只是把原图原样盖了一层。
    @Test func renderedImageShowsMagnifiedSource() throws {
        let source = try makeStripedImage(width: 120, height: 60)

        let control = EditorModel(image: source, title: "Control")
        let controlBitmap = NSBitmapImageRep(cgImage: try #require(control.renderedImage()))
        let controlAt40 = try #require(controlBitmap.colorAt(x: 40, y: 30))
        let controlAt50 = try #require(controlBitmap.colorAt(x: 50, y: 30))
        #expect(controlAt40.redComponent > 0.8)
        #expect(controlAt50.redComponent < 0.2)

        let model = EditorModel(image: source, title: "Magnified")
        model.setTool(.magnifier)
        model.add(EditorAnnotation(
            kind: .magnifier,
            start: CGPoint(x: 30, y: 10),
            end: CGPoint(x: 90, y: 50),
            style: model.activeStyle
        ))
        let bitmap = NSBitmapImageRep(cgImage: try #require(model.renderedImage()))
        // 竖条被放大推到 36..44：这里从白变黑。
        let magnifiedAt40 = try #require(bitmap.colorAt(x: 40, y: 30))
        #expect(magnifiedAt40.redComponent < 0.2)
        // 原来的位置（50）被推到框外，框内那一列回到白色。
        let magnifiedAt50 = try #require(bitmap.colorAt(x: 50, y: 30))
        #expect(magnifiedAt50.redComponent > 0.8)
        // 框外不受影响。
        let outside = try #require(bitmap.colorAt(x: 5, y: 30))
        #expect(outside.redComponent > 0.8)
    }

    // MARK: - 辅助

    private func makeStripedImage(width: Int, height: Int) throws -> CGImage {
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
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 48, y: 0, width: 4, height: height))
        return try #require(context.makeImage())
    }

    /// 纯灰图：几何 / 样式测试不关心像素内容。
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
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
