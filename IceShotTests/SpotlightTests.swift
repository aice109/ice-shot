import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 聚光灯：压暗的区域判定、样式、裁剪 / 旋转映射，以及导出的确烧进了压暗。
@MainActor
struct SpotlightTests {
    // MARK: - 工具与样式

    @Test func spotlightToolBelongsToMoreGroup() {
        // 聚光灯收口进「更多」，不再独占一格。
        #expect(EditorTool.spotlight.toolGroup == .more)
        #expect(EditorTool.ToolGroup.more.members.contains(.spotlight))
        #expect(EditorTool.spotlight.shortcut == "s")
        #expect(EditorTool.spotlight.annotationKind == .spotlight)
    }

    @Test func spotlightOptionsHaveNoColorOrWidth() {
        let options = EditorToolOptions(tool: .spotlight)
        #expect(options.isPresented)
        #expect(options.showsSpotlight)
        #expect(options.showsColor == false)
        #expect(options.widthRole == nil)
        #expect(options.showsRedaction == false)
        #expect(EditorToolOptions.spotlight.showsSpotlight)
    }

    @Test func spotlightStyleClampsDim() {
        var style = SpotlightStyle()
        #expect(style.shape == .ellipse)
        #expect(style.dim == SpotlightStyle.defaultDim)
        #expect(abs(style.clampedDim - SpotlightStyle.defaultDim) < 0.0001)

        style.dim = 5
        #expect(abs(style.clampedDim - SpotlightStyle.dimRange.upperBound) < 0.0001)
        style.dim = -1
        #expect(abs(style.clampedDim - SpotlightStyle.dimRange.lowerBound) < 0.0001)
    }

    @Test func activeStyleCarriesSpotlightSettings() throws {
        let model = EditorModel(image: try makeImage(width: 60, height: 40), title: "Test")
        model.setTool(.spotlight)
        model.setSpotlightShape(.rectangle)
        model.setSpotlightDim(0.45)
        let style = model.activeStyle
        #expect(style.spotlight?.shape == .rectangle)
        #expect(abs((style.spotlight?.dim ?? 0) - 0.45) < 0.0001)
        // 聚光灯不吃线宽，也不该被线宽滑块间接影响。
        #expect(style.lineWidth == 1)
    }

    @Test func settingDimUpdatesSelectedSpotlightAndUndoRestores() throws {
        let model = EditorModel(image: try makeImage(width: 60, height: 40), title: "Test")
        model.attachUndoManager(UndoManager())
        model.setTool(.spotlight)
        model.add(spotlight(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30), style: model.activeStyle))
        model.select(try #require(model.annotations.first).id)

        model.setSpotlightDim(0.35)
        #expect(abs((model.annotations.first?.spotlightStyle.dim ?? 0) - 0.35) < 0.0001)

        model.commitSpotlightChange()
        model.undo()
        #expect(abs((model.annotations.first?.spotlightStyle.dim ?? 0) - SpotlightStyle.defaultDim) < 0.0001)
    }

    // MARK: - 几何

    @Test func onlyInsideTheLitAreaIsHittable() {
        let annotation = spotlight(
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 80, y: 60),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1)
        )
        #expect(annotation.bounds == CGRect(x: 20, y: 20, width: 60, height: 40))
        // 亮区里命中。
        #expect(annotation.hitTest(CGPoint(x: 50, y: 40)))
        // 压暗区（亮区之外、整幅图内）不命中：否则它会抢走点其它标注的事件。
        #expect(annotation.hitTest(CGPoint(x: 2, y: 2)) == false)
        #expect(annotation.hitTest(CGPoint(x: 95, y: 70)) == false)
    }

    @Test func croppingKeepsTheLitAreaInsideTheNewCanvas() throws {
        let annotation = spotlight(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 90, y: 60),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1)
        )
        let crop = CGRect(x: 40, y: 20, width: 40, height: 30)
        let remapped = try #require(
            AnnotationCropper.remap(annotation, croppingTo: crop)
        )
        #expect(remapped.bounds == CGRect(x: 0, y: 0, width: 40, height: 30))

        // 完全在裁剪框外的聚光灯直接丢掉。
        let far = spotlight(
            from: CGPoint(x: 200, y: 200),
            to: CGPoint(x: 260, y: 240),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1)
        )
        #expect(AnnotationCropper.remap(far, croppingTo: crop) == nil)
    }

    @Test func rotationMapsTheLitArea() throws {
        let annotation = spotlight(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 50, y: 60),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1)
        )
        let rotated = AnnotationTransformer.rotated(
            [annotation],
            imageSize: CGSize(width: 100, height: 200),
            clockwise: true
        )
        let first = try #require(rotated.first)
        #expect(first.kind == .spotlight)
        #expect(first.bounds == CGRect(x: 140, y: 10, width: 40, height: 40))
    }

    // MARK: - 导出一致性

    @Test func renderedImageContainsTheDimming() throws {
        let model = EditorModel(image: try makeImage(width: 100, height: 60), title: "Test")
        model.setTool(.spotlight)
        model.add(spotlight(
            from: CGPoint(x: 30, y: 15),
            to: CGPoint(x: 70, y: 45),
            style: model.activeStyle
        ))
        let rendered = try #require(model.renderedImage())
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        // 原图是纯白；亮区保持亮，压暗区应该明显变暗。
        let inside = try #require(bitmap.colorAt(x: 50, y: 30))
        let outside = try #require(bitmap.colorAt(x: 5, y: 5))
        #expect(inside.redComponent > 0.9)
        #expect(outside.redComponent < 0.6)
    }

    // MARK: - 辅助

    private func spotlight(
        from start: CGPoint,
        to end: CGPoint,
        style: AnnotationStyle
    ) -> EditorAnnotation {
        EditorAnnotation(kind: .spotlight, start: start, end: end, style: style)
    }

    /// 纯白图：压暗与否一眼可测。
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
