import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

@MainActor
struct EditorTextAndFilterTests {
    @Test func textAnnotationUsesMeasuredBoundsAndHitsInside() {
        let annotation = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 20, y: 40),
            end: CGPoint(x: 20, y: 40),
            text: "IceShot 标注",
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1, fontSize: 32)
        )
        let size = annotation.measuredTextSize
        #expect(size.width > 0)
        #expect(abs(size.height - 38) < 8)

        let bounds = annotation.bounds
        #expect(bounds.origin == CGPoint(x: 20, y: 40))
        #expect(bounds.size == size)
        #expect(annotation.hitTest(CGPoint(x: 24, y: 50)))
        #expect(!annotation.hitTest(CGPoint(x: 20 + size.width + 40, y: 50)))

        let moved = annotation.offsetBy(dx: 5, dy: 6)
        #expect(moved.bounds.origin == CGPoint(x: 25, y: 46))
        #expect(moved.text == annotation.text)
    }

    @Test func emptyTextHasNoBounds() {
        let annotation = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 10, y: 10),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1, fontSize: 24)
        )
        #expect(annotation.bounds.size == .zero)
    }

    @Test func updatingAnnotationRegistersUndo() throws {
        let model = EditorModel(image: try makeImage(width: 80, height: 60), title: "Test")
        model.attachUndoManager(UndoManager())
        let original = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 5, y: 5),
            end: CGPoint(x: 5, y: 5),
            text: "旧",
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1, fontSize: 20)
        )
        model.add(original)
        var edited = original
        edited.text = "新文字"
        model.update(edited)
        #expect(model.annotations.first?.text == String(localized: "新文字"))

        model.undo()
        #expect(model.annotations.first?.text == String(localized: "旧"))
        model.redo()
        #expect(model.annotations.first?.text == String(localized: "新文字"))

        model.delete(id: original.id)
        #expect(model.annotations.isEmpty)
        model.undo()
        #expect(model.annotations.count == 1)
    }

    @Test func strokeFilterReturnsPaddedRegion() throws {
        let source = try makeImage(width: 200, height: 120)
        let cache = MarkupFilterCache()
        let annotation = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 40, y: 60), CGPoint(x: 120, y: 60)],
            brushWidth: 24,
            amount: 16
        )
        let result = try #require(cache.result(for: annotation, source: source))
        // 包围盒 (40,60,80,0) 外扩 笔宽/2 + 块大小 + 2 = 30，再裁到图像内。
        #expect(result.rect == CGRect(x: 10, y: 30, width: 140, height: 60))
        #expect(result.image.width == 140)
        #expect(result.image.height == 60)

        // 同一参数命中缓存；笔迹变化会重新生成。
        let cached = try #require(cache.result(for: annotation, source: source))
        #expect(cached.image === result.image)
        var moved = annotation
        moved.points = moved.points.map { CGPoint(x: $0.x + 12, y: $0.y) }
        let regenerated = try #require(cache.result(for: moved, source: source))
        #expect(regenerated.rect != result.rect)
    }

    @Test func strokeMaskOnlyPaintsPaintedArea() throws {
        let source = try makeGradientImage(width: 200, height: 80)
        let cache = MarkupFilterCache()
        // 水平笔迹覆盖 x 20…180，笔宽 24 → 实际涂抹 x 8…192。
        let annotation = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 20, y: 40), CGPoint(x: 180, y: 40)],
            brushWidth: 24,
            amount: 16
        )
        let result = try #require(cache.result(for: annotation, source: source))
        let pixels = try pixels(of: result.image)

        // 笔迹外透明：不会用原图盖掉先画的标注。
        for imagePoint in [CGPoint(x: 2, y: 40), CGPoint(x: 197, y: 40), CGPoint(x: 100, y: 61)] {
            let pixel = try pixel(in: pixels, result: result, at: imagePoint)
            #expect(pixel.a == 0)
        }
        // 笔迹内不透明。
        #expect(try pixel(in: pixels, result: result, at: CGPoint(x: 56, y: 40)).a == 255)
        #expect(try pixel(in: pixels, result: result, at: CGPoint(x: 120, y: 40)).a == 255)
    }

    @Test func overlappingStrokesKeepPreviousPaint() throws {
        let source = try makeGradientImage(width: 200, height: 80)
        let cache = MarkupFilterCache()
        let first = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 20, y: 40), CGPoint(x: 180, y: 40)],
            brushWidth: 24,
            amount: 16
        )
        // 第二条竖笔迹只在自己的笔迹内不透明，重叠处仍由第一条继续显示。
        let second = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 70)],
            brushWidth: 24,
            amount: 16
        )
        let firstResult = try #require(cache.result(for: first, source: source))
        let secondResult = try #require(cache.result(for: second, source: source))
        let secondPixels = try pixels(of: secondResult.image)
        #expect(try pixel(in: secondPixels, result: secondResult, at: CGPoint(x: 100, y: 40)).a == 255)
        #expect(try pixel(in: secondPixels, result: secondResult, at: CGPoint(x: 75, y: 40)).a == 0)
        #expect(firstResult.image !== secondResult.image)
    }

    @Test func pixelateBlocksAlignToImageLattice() throws {
        let source = try makeGradientImage(width: 256, height: 80)
        let cache = MarkupFilterCache()
        let annotation = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 16, y: 40), CGPoint(x: 240, y: 40)],
            brushWidth: 40,
            amount: 16
        )
        let result = try #require(cache.result(for: annotation, source: source))
        let rendered = try pixels(of: result.image)

        // 块大小 16：块内部像素一致（跳过落在块边界上的网格线），
        // 相邻块的底色不同。
        for blockStart in stride(from: 48, to: 176, by: 16) {
            let values = try (1..<16).map { offset in
                try pixel(in: rendered, result: result, at: CGPoint(x: blockStart + offset, y: 40)).r
            }
            #expect(Set(values).count == 1)

            let nextBlock = try pixel(
                in: rendered,
                result: result,
                at: CGPoint(x: blockStart + 17, y: 40)
            ).r
            #expect(values[0] != nextBlock)
        }
    }

    @Test func blurFilterOnlyHandlesPixelKinds() throws {
        let source = try makeImage(width: 60, height: 60)
        let cache = MarkupFilterCache()
        let line = EditorAnnotation(
            kind: .line,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 50, y: 50),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 4, opacity: 1)
        )
        #expect(cache.result(for: line, source: source) == nil)

        let singlePoint = brushAnnotation(kind: .blur, points: [CGPoint(x: 10, y: 10)])
        #expect(cache.result(for: singlePoint, source: source) == nil)

        let blur = brushAnnotation(
            kind: .blur,
            points: [CGPoint(x: 10, y: 30), CGPoint(x: 50, y: 30)]
        )
        let result = try #require(cache.result(for: blur, source: source))
        #expect(result.rect.width >= 40)
        #expect(result.rect.height >= 1)
    }

    @Test func previewIsDownsampledButKeepsTargetRect() throws {
        let source = try makeImage(width: 1600, height: 400)
        let cache = MarkupFilterCache()
        let annotation = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 0, y: 200), CGPoint(x: 1600, y: 200)],
            brushWidth: 400,
            amount: 16
        )

        let preview = try #require(cache.result(for: annotation, source: source, preview: true))
        #expect(preview.isPreview)
        #expect(preview.rect == CGRect(x: 0, y: 0, width: 1600, height: 400))
        #expect(preview.image.width < 1600)
        #expect(preview.image.width == Int(MarkupFilterCache.previewDimension))

        let full = try #require(cache.result(for: annotation, source: source))
        #expect(!full.isPreview)
        #expect(full.image.width == 1600)
        #expect(full.image.height == 400)
    }

    @Test func previewMaskStaysOnStrokeAfterDownsampling() throws {
        let source = try makeImage(width: 1600, height: 400)
        let cache = MarkupFilterCache()
        // 笔迹覆盖图像 y 180…220（笔宽 40），裁剪区是 y 162…238。
        let annotation = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 0, y: 200), CGPoint(x: 1600, y: 200)],
            brushWidth: 40,
            amount: 16
        )
        let preview = try #require(cache.result(for: annotation, source: source, preview: true))
        let buffer = try pixels(of: preview.image)
        // 预览是降采样位图：图像坐标要先按「位图尺寸 / 裁剪区尺寸」换算再取样。
        let scaleX = CGFloat(preview.image.width) / preview.rect.width
        let scaleY = CGFloat(preview.image.height) / preview.rect.height
        func sample(_ x: CGFloat, _ y: CGFloat) throws -> Pixel {
            // 取「包含该点的像素」，用向下取整；四舍五入会把最后一行 / 一列取到位图外。
            try pixel(
                in: buffer,
                x: Int(((x - preview.rect.minX) * scaleX).rounded(.down)),
                y: Int(((y - preview.rect.minY) * scaleY).rounded(.down))
            )
        }

        #expect(try sample(800, 200).a == 255)
        // 涂抹以外必须透明：遮罩曾经按原图坐标画在缩小的位图上，
        // 拖拽预览就会「漂移变大」，松手才恢复正常。
        for y in [CGFloat(167), 172, 232, 237] {
            #expect(try sample(800, y).a == 0)
        }
        #expect(try sample(1590, 200).a == 255)
    }

    @Test func redactionStylesProduceDifferentPixels() throws {
        let source = try makeGradientImage(width: 240, height: 60)
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 220, y: 30)]
        var samples: [RedactionStyle: [Int]] = [:]

        for style in RedactionStyle.allCases {
            let cache = MarkupFilterCache()
            let annotation = brushAnnotation(
                kind: .pixelate,
                points: points,
                brushWidth: 40,
                amount: 16,
                style: style
            )
            let result = try #require(cache.result(for: annotation, source: source))
            let pixels = try pixels(of: result.image)
            // 遮罩仍然生效：笔迹外透明、笔迹内不透明。
            #expect(try pixel(in: pixels, result: result, at: CGPoint(x: 20, y: 3)).a == 0)
            #expect(try pixel(in: pixels, result: result, at: CGPoint(x: 120, y: 30)).a == 255)
            samples[style] = try (100..<120).map {
                try pixel(in: pixels, result: result, at: CGPoint(x: $0, y: 30)).r
            }
        }

        let mosaic = try #require(samples[.mosaic])
        let blur = try #require(samples[.blur])
        let noise = try #require(samples[.noise])
        let solid = try #require(samples[.solid])
        #expect(mosaic != blur)
        #expect(mosaic != noise)
        #expect(blur != noise)
        #expect(solid.allSatisfy { $0 == solid[0] })
        #expect(solid != mosaic)
    }

    @Test func mosaicGridStaysVisibleOnFlatColors() throws {
        // 纯色底：只做像素化等于什么都没变，网格让打码可见（这是用户反馈的问题）。
        let points = [CGPoint(x: 20, y: 40), CGPoint(x: 180, y: 40)]

        for level in [CGFloat(0), 0.5, 1] {
            let source = try makeFlatImage(width: 200, height: 80, level: level)
            let sourcePixels = try pixels(of: source)
            let baseValue = sourcePixels.values[5 * sourcePixels.width + 5].r

            let cache = MarkupFilterCache()
            let annotation = brushAnnotation(
                kind: .pixelate,
                points: points,
                brushWidth: 40,
                amount: 16,
                style: .mosaic
            )
            let result = try #require(cache.result(for: annotation, source: source))
            let pixels = try pixels(of: result.image)
            let values = try (60..<140).map {
                try pixel(in: pixels, result: result, at: CGPoint(x: $0, y: 40)).r
            }

            #expect(Set(values).count > 1)
            // 网格线与底色的差值足够大，白底 / 黑底 / 中灰底都能一眼看到。
            let maxDelta = values.map { abs($0 - baseValue) }.max() ?? 0
            #expect(maxDelta >= 8)
        }
    }

    @Test func redactionStyleFollowsSelectedAnnotation() throws {
        let image = try makeImage(width: 120, height: 120)
        let model = EditorModel(image: image, title: "test")
        let annotation = brushAnnotation(
            kind: .pixelate,
            points: [CGPoint(x: 10, y: 60), CGPoint(x: 110, y: 60)],
            brushWidth: 40,
            amount: 16,
            style: .mosaic
        )
        model.add(annotation)
        model.select(annotation.id)

        model.setRedactionStyle(.noise)
        #expect(model.selectedAnnotation?.redactionStyle == .noise)
        model.commitFilterChange()
        #expect(model.canUndo)
        model.undo()
        #expect(model.selectedAnnotation?.redactionStyle == .mosaic)

        // 新建标注沿用当前样式（撤销只回滚标注，不回滚工具默认值）。
        model.setTool(.pixelate)
        #expect(model.activeStyle.redactionStyle == .noise)
        model.setRedactionStyle(.solid)
        #expect(model.activeStyle.redactionStyle == .solid)
        #expect(model.activeStyle.filterAmount != nil)

        // 样式跟着工具记住：切走再切回马赛克，仍是用户选的纯色。
        model.setTool(.select)
        model.setTool(.pixelate)
        #expect(model.activeStyle.redactionStyle == .solid)
    }

    @Test func filterAmountDefaultsToLineWidthWhenUnset() {
        let legacy = EditorAnnotation(
            kind: .pixelate,
            start: .zero,
            end: CGPoint(x: 10, y: 10),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 4, opacity: 1)
        )
        #expect(legacy.filterAmount == 12)

        let explicit = EditorAnnotation(
            kind: .pixelate,
            start: .zero,
            end: CGPoint(x: 10, y: 10),
            style: AnnotationStyle(
                color: .defaultRed,
                lineWidth: 4,
                opacity: 1,
                filterAmount: 24
            )
        )
        #expect(explicit.filterAmount == 24)
    }

    @Test func filterAmountFollowsSelectedAnnotation() throws {
        let image = try makeImage(width: 120, height: 120)
        let model = EditorModel(image: image, title: "test")
        let annotation = EditorAnnotation(
            kind: .pixelate,
            start: CGPoint(x: 16, y: 16),
            end: CGPoint(x: 96, y: 96),
            style: AnnotationStyle(
                color: .defaultRed,
                lineWidth: 4,
                opacity: 1,
                filterAmount: 16
            )
        )
        model.add(annotation)
        model.select(annotation.id)

        model.setFilterAmount(24)
        let updated = try #require(model.selectedAnnotation)
        #expect(updated.style.filterAmount == 24)
        #expect(updated.filterAmount == 24)

        model.commitFilterChange()
        #expect(model.canUndo)
        model.undo()
        #expect(model.selectedAnnotation?.filterAmount == 16)

        // 新建标注沿用当前块大小。
        model.setTool(.pixelate)
        #expect(model.activeStyle.filterAmount == 24)
    }

    private func brushAnnotation(
        kind: AnnotationKind,
        points: [CGPoint],
        brushWidth: CGFloat = 24,
        amount: CGFloat = 16,
        style: RedactionStyle = .mosaic
    ) -> EditorAnnotation {
        EditorAnnotation(
            kind: kind,
            start: points.first ?? .zero,
            end: points.last ?? .zero,
            points: points,
            style: AnnotationStyle(
                color: .defaultRed,
                lineWidth: brushWidth,
                opacity: 1,
                filterAmount: amount,
                redactionStyle: style
            )
        )
    }

    private struct Pixel {
        let r: Int
        let g: Int
        let b: Int
        let a: Int
    }

    private struct PixelBuffer {
        let values: [Pixel]
        let width: Int
    }

    private func pixels(of image: CGImage) throws -> PixelBuffer {
        let bytesPerPixel = image.bitsPerPixel / 8
        let data = try #require(image.dataProvider?.data) as Data
        var values: [Pixel] = []
        values.reserveCapacity(image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                values.append(
                    Pixel(
                        r: Int(data[offset]),
                        g: bytesPerPixel >= 2 ? Int(data[offset + 1]) : Int(data[offset]),
                        b: bytesPerPixel >= 3 ? Int(data[offset + 2]) : Int(data[offset]),
                        a: bytesPerPixel >= 4 ? Int(data[offset + 3]) : 255
                    )
                )
            }
        }
        return PixelBuffer(values: values, width: image.width)
    }

    private func pixel(
        in buffer: PixelBuffer,
        result: MarkupFilterCache.Result,
        at imagePoint: CGPoint
    ) throws -> Pixel {
        try pixel(
            in: buffer,
            x: Int(imagePoint.x - result.rect.minX),
            y: Int(imagePoint.y - result.rect.minY)
        )
    }

    /// 按位图坐标（左上原点）取样。
    private func pixel(in buffer: PixelBuffer, x: Int, y: Int) throws -> Pixel {
        let index = y * buffer.width + x
        guard buffer.values.indices.contains(index) else {
            throw TestError.outOfBounds
        }
        return buffer.values[index]
    }

    private enum TestError: Error {
        case outOfBounds
    }

    // MARK: - 文字背景

    @Test func textBackgroundExpandsBoundsAndHitArea() throws {
        let plain = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 40, y: 40),
            end: CGPoint(x: 40, y: 40),
            text: "背景",
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1, fontSize: 32)
        )
        #expect(plain.textBackground == .none)
        #expect(plain.textBackgroundPadding == 0)
        #expect(plain.bounds == CGRect(origin: plain.start, size: plain.measuredTextSize))

        var styled = plain
        styled.style.textBackground = .solid
        let padding = styled.textBackgroundPadding
        #expect(padding > 0)
        #expect(styled.textBoxRect.width == plain.measuredTextSize.width + padding * 2)
        #expect(styled.textBoxRect.height == plain.measuredTextSize.height + padding * 2)
        // 背景向外扩，字形锚点不变（就是文字左上角）。
        #expect(styled.bounds.minX == plain.start.x - padding)
        #expect(styled.bounds.minY == plain.start.y - padding)
        // 内边距里也算命中（点背景块就是在点这条文字）。
        #expect(styled.hitTest(CGPoint(x: plain.start.x - padding + 1, y: plain.start.y + 4)))
        #expect(!plain.hitTest(CGPoint(x: plain.start.x - padding + 1, y: plain.start.y + 4)))
    }

    @Test func textBackgroundPaddingFollowsFontSize() {
        func padding(fontSize: CGFloat) -> CGFloat {
            var style = AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1, fontSize: fontSize)
            style.textBackground = .translucent
            return EditorAnnotation(
                kind: .text,
                start: .zero,
                end: .zero,
                text: "A",
                style: style
            ).textBackgroundPadding
        }
        #expect(padding(fontSize: 40) > padding(fontSize: 20))
    }

    @Test func readableTextColorPicksContrast() {
        #expect(EditorColor.readableLight.readableTextColor == .readableDark)
        #expect(EditorColor.readableDark.readableTextColor == .readableLight)
        let yellow = EditorColor(red: 1, green: 0.8, blue: 0, alpha: 1)
        let blue = EditorColor(red: 0, green: 0.48, blue: 1, alpha: 1)
        #expect(yellow.readableTextColor == .readableDark)
        #expect(blue.readableTextColor == .readableLight)
    }

    @Test func selectingBackgroundUpdatesSelectedTextAnnotation() throws {
        let model = EditorModel(image: try makeImage(width: 120, height: 80), title: "Test")
        model.attachUndoManager(UndoManager())
        model.setTool(.text)
        let annotation = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 10, y: 10),
            text: "读我",
            style: model.activeStyle
        )
        model.add(annotation)
        model.select(annotation.id)

        model.setTextBackground(.solid)
        #expect(model.annotations.first?.style.textBackground == .solid)

        model.undo()
        // `activeStyle` 会把当时的样式（含 `.none`）写进标注，所以撤销后回的是 `.none`。
        // 注意这里要写全 `TextBackgroundStyle.none`：可选值上下文里裸 `.none` 会被当成 `nil`。
        #expect(model.annotations.first?.style.textBackground == TextBackgroundStyle.none)
    }

    @Test func backgroundBoxStaysInsideAfterRotation() throws {
        var style = AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1, fontSize: 32)
        style.textBackground = .solid
        let annotation = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 4, y: 4),
            end: CGPoint(x: 4, y: 4),
            text: "贴边文字",
            style: style
        )
        let rotated = AnnotationTransformer.rotated(
            [annotation],
            imageSize: CGSize(width: 400, height: 200),
            clockwise: true
        ).first
        let result = try #require(rotated)
        #expect(result.bounds.minX >= 0)
        #expect(result.bounds.minY >= 0)
        #expect(result.bounds.maxX <= 200)
        #expect(result.bounds.maxY <= 400)
    }

    private func makeGradientImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for x in 0..<width {
            context.setFillColor(CGColor(
                red: CGFloat(x) / CGFloat(width),
                green: 0,
                blue: 0,
                alpha: 1
            ))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return try #require(context.makeImage())
    }

    private func makeFlatImage(width: Int, height: Int, level: CGFloat) throws -> CGImage {
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
        context.setFillColor(CGColor(gray: level, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
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
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }
}
