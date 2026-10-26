import AppKit
import CoreGraphics
import Testing
@testable import IceShot

/// M2「输出接入」的行为锁定。
///
/// 这一层的风险不是「壳画得好不好看」（那由 `ScreenshotFrameComposerTests` 管），
/// 而是三件会直接伤到用户数据或成品的事：
///
/// 1. **关闭带壳后必须与原图逐像素一致** —— 不许悄悄多走一次重绘；
/// 2. **顺序必须是先裁剪后套壳** —— 顺序反了壳会被裁掉一半；
/// 3. **历史库只收原图** —— 带壳图进了历史，用户就再也拿不回干净版本。
@MainActor
struct ScreenshotFrameExportTests {
    // MARK: - 统一合成入口

    @Test("无样式、无裁剪：原样返回同一张图，不重绘")
    func composeWithoutStyleReturnsContent() throws {
        let content = try makeQuadrantImage()
        let output = try ScreenshotFrameComposer.compose(content, cropRect: nil, style: nil)

        #expect(output.width == content.width)
        #expect(output.height == content.height)
        // 「不多经过一次重绘」的判据：像素与原图逐格一致。
        #expect(try pixelsAreEqual(output, content))
    }

    @Test("无样式、有裁剪：只裁剪，不套壳")
    func composeWithoutStyleCrops() throws {
        let content = try makeQuadrantImage()   // 1000 × 1000 四象限
        let output = try ScreenshotFrameComposer.compose(
            content,
            cropRect: CGRect(x: 0, y: 0, width: 500, height: 500),
            style: nil
        )

        #expect(output.width == 500)
        #expect(output.height == 500)
        // 左上象限是红色（CGImage 坐标 (0,0) = 图像左上）。
        let center = try pixel(in: output, x: 250, y: 250)
        #expect(center.isNear(red: 0xFF, green: 0x00, blue: 0x00))
    }

    @Test("有样式、有裁剪：先裁剪后套壳，尺寸按裁剪后的内容算")
    func composeCropsBeforeFraming() throws {
        let content = try makeQuadrantImage()
        let output = try ScreenshotFrameComposer.compose(
            content,
            cropRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            style: .default
        )

        // u = clamp(500 / 1000, 0.8, 2.0) = 0.8；标题栏 28u = 22.4；中留白 64u = 51.2。
        // 注意取整点在**总尺寸**上，不是逐项取整后再相加。
        let unit: CGFloat = 0.8
        let padding = 64 * unit
        let titleBar = 28 * unit
        #expect(output.width == Int((500 + padding * 2).rounded()))
        #expect(output.height == Int((400 + titleBar + padding * 2).rounded()))
        // 关键反证：如果先套壳再裁剪，宽度会按整张 1000 px 内容算，远超上面的值。
        #expect(output.width < 1000)
    }

    @Test("裁剪矩形越界直接报错，不静默产出怪图")
    func composeRejectsInvalidCrop() throws {
        let content = try makeQuadrantImage()
        #expect(throws: (any Error).self) {
            try ScreenshotFrameComposer.compose(
                content,
                cropRect: CGRect(x: 5000, y: 5000, width: 10, height: 10),
                style: nil
            )
        }
    }

    // MARK: - 编辑器导出

    @Test("编辑器带壳关闭：导出与原图逐像素一致")
    func editorExportWithoutFrameMatchesSource() throws {
        let source = try makeQuadrantImage()
        let model = EditorModel(image: source, title: "测试")
        #expect(!model.isFrameEnabled)

        let exported = try #require(model.exportImage())
        #expect(exported.width == source.width)
        #expect(exported.height == source.height)
        #expect(try pixelsAreEqual(exported, source))
    }

    @Test("编辑器带壳开启：导出比内容大一圈")
    func editorExportWithFrameGrows() throws {
        let source = try makeSolidImage(width: 1000, height: 600)
        let model = EditorModel(image: source, title: "测试")

        model.setFrameEnabled(true)
        let exported = try #require(model.exportImage())

        // 窗口壳 + 中留白：1000 + 64×2 宽，600 + 28 + 64×2 高。
        #expect(exported.width == 1128)
        #expect(exported.height == 600 + 28 + 128)
    }

    @Test("浮层路径：裁剪矩形必须传进导出，壳才会按选区尺寸生成")
    func editorExportAppliesCropBeforeFrame() throws {
        let source = try makeQuadrantImage()   // 1000 × 1000
        let model = EditorModel(image: source, title: "测试")
        model.setFrameEnabled(true)

        // 只留左上 500 × 400 那一块。
        let exported = try #require(
            model.exportImage(cropRect: CGRect(x: 0, y: 0, width: 500, height: 400))
        )

        // 宽度由**裁剪后的内容**（500）算，而不是原图宽度（1000）。
        let unit: CGFloat = 0.8
        let padding = 64 * unit
        #expect(exported.width == Int((500 + padding * 2).rounded()))
        #expect(exported.height == Int((400 + 28 * unit + padding * 2).rounded()))
    }

    /// 这是上一个用例的反向断言：不带 `cropRect` 时成品宽度确实会按整图算。
    ///
    /// 两个用例一正一反，卡住「忘了把 `pixelRect` 传进去」这个具体回归——
    /// 它曾在本轮实现里真实发生过一次：浮层改走 `exportImage` 后漏了裁剪，
    /// 壳会套到整张冻结帧上。
    @Test("漏传裁剪：成品尺寸会按整图算，明显大于选区版")
    func editorExportWithoutCropIsLarger() throws {
        let source = try makeQuadrantImage()
        let model = EditorModel(image: source, title: "测试")
        model.setFrameEnabled(true)

        let cropped = try #require(
            model.exportImage(cropRect: CGRect(x: 0, y: 0, width: 500, height: 400))
        )
        let uncropped = try #require(model.exportImage())

        #expect(uncropped.width > cropped.width)
        // 不裁剪时按 1000 px 内容算：u = 1，留白 64。
        #expect(uncropped.width == 1000 + 64 * 2)
    }

    @Test("关掉带壳后导出恢复原图")
    func editorExportRestoresAfterDisabling() throws {
        let source = try makeQuadrantImage()
        let model = EditorModel(image: source, title: "测试")

        model.setFrameEnabled(true)
        model.setFrameEnabled(false)

        let exported = try #require(model.exportImage())
        #expect(exported.width == source.width)
        #expect(try pixelsAreEqual(exported, source))
    }

    @Test("带壳不改动模型里的原图与撤销栈")
    func frameDoesNotTouchModelImage() throws {
        let source = try makeQuadrantImage()
        let model = EditorModel(image: source, title: "测试")
        model.attachUndoManager(UndoManager())

        model.setFrameEnabled(true)
        model.setFrameStyle(ScreenshotFrameStyle(chrome: .shadowOnly))

        // 图像引用不变（历史库、画布、OCR 拿到的还是干净原图）。
        #expect(model.image === source)
        #expect(model.annotations.isEmpty)
        // 带壳是输出设置，不是标注，不进撤销栈。
        #expect(model.canUndo == false)
    }

    @Test("带壳只影响导出，不影响 renderedImage()")
    func renderedImageStaysFrameless() throws {
        let source = try makeSolidImage(width: 200, height: 100)
        let model = EditorModel(image: source, title: "测试")
        model.setFrameEnabled(true)

        let rendered = try #require(model.renderedImage())
        // 画布 / OCR / 取字都还用这张干净图。
        #expect(rendered.width == 200)
        #expect(rendered.height == 100)
    }

    // MARK: - 批量保存

    @Test("全部显示器：其余屏套同一个壳，当前屏不重复套")
    func batchFramesEveryDisplayOnce() throws {
        // 复刻 `CaptureCoordinator.framedBatch` 的约定：
        // 当前屏（index）进来时已经带壳，必须跳过，否则会得到壳外套壳。
        let style = ScreenshotFrameStyle.default
        let plain = try makeSolidImage(width: 1000, height: 600)
        let alreadyFramed = try ScreenshotFrameComposer.render(plain, style: style)

        var images = [plain, plain, plain]
        let index = 1
        images[index] = alreadyFramed

        let output = Self.applyFrame(images, index: index, style: style)

        // 当前屏尺寸没变（没有被套第二层）。
        #expect(output[1].width == alreadyFramed.width)
        #expect(output[1].height == alreadyFramed.height)
        // 其余屏都补齐了一层壳。
        #expect(output[0].width == 1128)
        #expect(output[2].width == 1128)
    }

    @Test("批量无样式时原样返回")
    func batchWithoutStyleIsUntouched() throws {
        let plain = try makeSolidImage(width: 300, height: 200)
        let output = Self.applyFrame([plain, plain], index: 0, style: nil)
        #expect(output[0] === plain)
        #expect(output[1] === plain)
    }

    // MARK: - 辅助

    /// 与 `CaptureCoordinator.framedBatch` 同构的纯函数，供测试在不上 UI 的前提下验证约定。
    private static func applyFrame(
        _ images: [CGImage],
        index: Int,
        style: ScreenshotFrameStyle?
    ) -> [CGImage] {
        guard let style else { return images }
        return images.enumerated().map { offset, image in
            guard offset != index else { return image }
            return (try? ScreenshotFrameComposer.render(image, style: style)) ?? image
        }
    }

    private func pixelsAreEqual(_ lhs: CGImage, _ rhs: CGImage) throws -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        let left = try #require(Self.bitmapData(lhs))
        let right = try #require(Self.bitmapData(rhs))
        return left == right
    }

    private static func bitmapData(_ image: CGImage) -> Data? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        return Data(bytes: data, count: image.width * image.height * 4)
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> RGBA {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            throw CaptureError.invalidSelection
        }
        var data = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &data,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(red: data[0], green: data[1], blue: data[2], alpha: data[3])
    }

    private struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        func isNear(red: UInt8, green: UInt8, blue: UInt8, tolerance: Int = 14) -> Bool {
            abs(Int(self.red) - Int(red)) <= tolerance
                && abs(Int(self.green) - Int(green)) <= tolerance
                && abs(Int(self.blue) - Int(blue)) <= tolerance
        }
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
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

    /// 四象限测试图：用来验证裁剪取到的确实是**那块**像素，而不是别处。
    private func makeQuadrantImage() throws -> CGImage {
        let size = 1000
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CGContext 是左下原点：y = 500...1000 落在图像上半部分。
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 500, width: 500, height: 500))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 500, width: 500, height: 500))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 500))
        return try #require(context.makeImage())
    }
}
