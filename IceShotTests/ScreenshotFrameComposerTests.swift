import CoreGraphics
import Testing
@testable import IceShot

/// 窗口壳渲染器的纯几何 / 像素断言。
///
/// 这些用例不追求「和真机窗口逐像素一致」，只锁住几件会直接影响成品的事：
/// 尺寸、圆角裁切后的透明角、投影、交通灯位置、明暗切换、预览缩放、内容方向。
@MainActor
struct ScreenshotFrameComposerTests {
    // MARK: - 尺寸

    @Test("窗口壳：内容 + 标题栏 + 两侧留白")
    func windowShellSize() throws {
        let content = try makeSolidImage(width: 1000, height: 600)
        let output = try ScreenshotFrameComposer.render(content, style: .default)
        // 1000 px 宽 → u = 1；标题栏 28；中留白 64。
        #expect(output.width == 1128)
        #expect(output.height == 600 + 28 + 64 * 2)
    }

    @Test("大图按内容宽度放大壳的比例")
    func largeContentScalesChrome() throws {
        let content = try makeSolidImage(width: 2000, height: 600)
        let output = try ScreenshotFrameComposer.render(content, style: .default)
        // u = 2；标题栏 56；中留白 128。
        #expect(output.width == 2000 + 128 * 2)
        #expect(output.height == 600 + 56 + 128 * 2)
    }

    @Test("仅阴影：没有标题栏")
    func shadowOnlyHasNoTitleBar() throws {
        var style = ScreenshotFrameStyle.default
        style.chrome = .shadowOnly
        let content = try makeSolidImage(width: 1000, height: 600)
        let output = try ScreenshotFrameComposer.render(content, style: style)
        #expect(output.width == 1128)
        #expect(output.height == 600 + 64 * 2)
    }

    @Test("预览按长边限制尺寸")
    func previewRespectsMaximumDimension() throws {
        let content = try makeSolidImage(width: 2000, height: 600)
        let output = try ScreenshotFrameComposer.render(
            content,
            style: .default,
            maximumDimension: 400
        )
        #expect(max(output.width, output.height) <= 400)
    }

    // MARK: - 背景

    @Test("透明底：画布四角是透明像素")
    func transparentCornersStayClear() throws {
        var style = ScreenshotFrameStyle.default
        style.background = .transparent
        let content = try makeSolidImage(width: 1000, height: 600)
        let output = try ScreenshotFrameComposer.render(content, style: style)
        let corner = try #require(pixel(in: output, x: 0, y: 0))
        #expect(corner.alpha == 0)
    }

    @Test("渐变底：画布四角不透明")
    func gradientCornersAreOpaque() throws {
        var style = ScreenshotFrameStyle.default
        style.background = .graphite
        let content = try makeSolidImage(width: 1000, height: 600)
        let output = try ScreenshotFrameComposer.render(content, style: style)
        let corner = try #require(pixel(in: output, x: 0, y: 0))
        #expect(corner.alpha == 255)
    }

    // MARK: - 明暗

    @Test("自动外观：白色内容用浅色标题栏，黑色内容用深色")
    func autoAppearanceFollowsContent() throws {
        var style = ScreenshotFrameStyle.default
        style.appearance = .automatic

        let lightOutput = try ScreenshotFrameComposer.render(
            makeSolidImage(width: 1000, height: 600, color: .white),
            style: style
        )
        let darkOutput = try ScreenshotFrameComposer.render(
            makeSolidImage(width: 1000, height: 600, color: .black),
            style: style
        )

        // 标题栏中间、避开交通灯和标题。
        let lightPixel = try #require(pixel(in: lightOutput, x: 600, y: 78))
        let darkPixel = try #require(pixel(in: darkOutput, x: 600, y: 78))
        #expect(lightPixel.luminance > 200)
        #expect(darkPixel.luminance < 80)
    }

    @Test("手动指定深色时，白色内容也用深色标题栏")
    func manualAppearanceWins() throws {
        var style = ScreenshotFrameStyle.default
        style.appearance = .dark
        let output = try ScreenshotFrameComposer.render(
            makeSolidImage(width: 1000, height: 600, color: .white),
            style: style
        )
        let sample = try #require(pixel(in: output, x: 600, y: 78))
        #expect(sample.luminance < 80)
    }

    // MARK: - 交通灯

    @Test("红黄绿在标题栏左侧的预期位置")
    func trafficLightsAreAtExpectedCenters() throws {
        let content = try makeSolidImage(width: 1000, height: 600)
        let output = try ScreenshotFrameComposer.render(content, style: .default)

        // 窗口左边缘 = 64；标题栏中心 = 64 + 14 = 78。
        // 圆直径 12、间距 8、左边距 20：圆心 90 / 110 / 130。
        let close = try #require(pixel(in: output, x: 90, y: 78))
        let minimize = try #require(pixel(in: output, x: 110, y: 78))
        let zoom = try #require(pixel(in: output, x: 130, y: 78))

        #expect(close.isNear(red: 0xFF, green: 0x5F, blue: 0x57))
        #expect(minimize.isNear(red: 0xFE, green: 0xBC, blue: 0x2E))
        #expect(zoom.isNear(red: 0x28, green: 0xC8, blue: 0x40))
    }

    // MARK: - 投影

    @Test("投影开：窗口下方有半透明像素；关：没有")
    func shadowCanBeTurnedOff() throws {
        var withShadow = ScreenshotFrameStyle.default
        withShadow.background = .transparent
        withShadow.showsShadow = true
        var withoutShadow = withShadow
        withoutShadow.showsShadow = false

        let content = try makeSolidImage(width: 1000, height: 600)
        let shadowed = try ScreenshotFrameComposer.render(content, style: withShadow)
        let flat = try ScreenshotFrameComposer.render(content, style: withoutShadow)

        // 窗口下边缘 = 64 + 600 + 28 = 692；往下 8 px 仍在 64 px 的留白里。
        let shadowedPixel = try #require(pixel(in: shadowed, x: 600, y: 700))
        let flatPixel = try #require(pixel(in: flat, x: 600, y: 700))
        #expect(shadowedPixel.alpha > 0)
        #expect(flatPixel.alpha == 0)
    }

    // MARK: - 内容方向

    @Test("内容图不会上下颠倒")
    func contentIsDrawnUpright() throws {
        var style = ScreenshotFrameStyle.default
        style.chrome = .shadowOnly
        style.padding = .medium
        style.background = .transparent
        style.showsShadow = false

        let content = try makeQuadrantImage()
        let output = try ScreenshotFrameComposer.render(content, style: style)

        // 内容从 (64, 64) 开始，1000 × 1000；四象限中心。
        let topLeft = try #require(pixel(in: output, x: 64 + 250, y: 64 + 250))
        let topRight = try #require(pixel(in: output, x: 64 + 750, y: 64 + 250))
        let bottomLeft = try #require(pixel(in: output, x: 64 + 250, y: 64 + 750))
        let bottomRight = try #require(pixel(in: output, x: 64 + 750, y: 64 + 750))

        #expect(topLeft.isNear(red: 0xFF, green: 0x00, blue: 0x00))
        #expect(topRight.isNear(red: 0x00, green: 0xFF, blue: 0x00))
        #expect(bottomLeft.isNear(red: 0x00, green: 0x00, blue: 0xFF))
        #expect(bottomRight.isNear(red: 0xFF, green: 0xFF, blue: 0x00))
    }

    // MARK: - 标题

    @Test("长标题不越界、不崩溃")
    func longTitleRenders() throws {
        var style = ScreenshotFrameStyle.default
        style.title = String(repeating: "Very long window title ", count: 20)
        let content = try makeSolidImage(width: 1000, height: 600)
        let output = try ScreenshotFrameComposer.render(content, style: style)
        #expect(output.width == 1128)
    }

    // MARK: - 辅助

    private enum SolidColor {
        case white
        case black
    }

    private func makeSolidImage(
        width: Int,
        height: Int,
        color: SolidColor = .white
    ) throws -> CGImage {
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
        switch color {
        case .white:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
        case .black:
            context.setFillColor(CGColor(gray: 0, alpha: 1))
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func makeQuadrantImage() throws -> CGImage {
        let width = 1000
        let height = 1000
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
        // CGContext 是左下原点：y = 500...1000 是上半部分。
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

    private func pixel(in image: CGImage, x: Int, y: Int) -> RGBA? {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return nil
        }
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(red: data[0], green: data[1], blue: data[2], alpha: data[3])
    }

    private struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        var luminance: Int {
            (Int(red) * 2126 + Int(green) * 7152 + Int(blue) * 722) / 10_000
        }

        func isNear(red: UInt8, green: UInt8, blue: UInt8, tolerance: Int = 14) -> Bool {
            abs(Int(self.red) - Int(red)) <= tolerance
                && abs(Int(self.green) - Int(green)) <= tolerance
                && abs(Int(self.blue) - Int(blue)) <= tolerance
        }
    }
}
