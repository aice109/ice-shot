import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 设备壳渲染器的几何与像素断言。
///
/// 只锁会直接影响成品的事：尺寸、刘海位置与遮挡、机身配色可区分、
/// 外观三档的 chrome 分配、以及「设备壳与窗口壳互斥」这条产品约束。
@MainActor
struct DeviceFrameComposerTests {
    // MARK: - 尺寸

    @Test("输出尺寸 = 内容 + 黑边 + 下巴 + 留白")
    func outputSizeMatchesSpec() throws {
        let content = try makeImage(width: 1000, height: 600)
        let style = DeviceFrameStyle.default   // 中留白 52u

        let output = try DeviceFrameComposer.render(content, style: style)
        let expected = DeviceFrameComposer.outputSize(
            for: CGSize(width: 1000, height: 600),
            style: style
        )
        #expect(output.width == Int(expected.width.rounded()))
        #expect(output.height == Int(expected.height.rounded()))

        // u = 1：机身边框 8 + 黑边 20 = 每侧 28；下巴 22；中留白 52。
        #expect(output.width == 1000 + (8 + 20) * 2 + 52 * 2)
        #expect(output.height == 600 + (8 + 20) * 2 + 22 + 52 * 2)
    }

    @Test("大内容按比例放大机身")
    func largeContentScales() throws {
        let content = try makeImage(width: 2000, height: 1200)
        let style = DeviceFrameStyle.default   // u = 2

        let output = try DeviceFrameComposer.render(content, style: style)
        // u = 2：边框与黑边、下巴、留白全部翻倍。
        #expect(output.width == 2000 + (8 + 20) * 2 * 2 + 104 * 2)
        #expect(output.height == 1200 + (8 + 20) * 2 * 2 + 22 * 2 + 104 * 2)
    }

    @Test("预览按长边降采样")
    func previewIsDownscaled() throws {
        let content = try makeImage(width: 1000, height: 600)
        let full = try DeviceFrameComposer.render(content, style: .default)
        let preview = try DeviceFrameComposer.render(content, style: .default, maximumDimension: 400)

        #expect(max(preview.width, preview.height) <= 400)
        #expect(preview.width < full.width)
    }

    // MARK: - 刘海

    @Test("刘海压在屏幕顶部正中，且遮住内容")
    func notchCoversContentTopCenter() throws {
        // 纯白内容最容易看出遮挡：刘海区域应变成黑色。
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        let output = try DeviceFrameComposer.render(content, style: .default)

        let padding = 52
        let rim = 8
        let bezel = 20
        let screenMidX = padding + rim + bezel + (1000 / 2)
        // 屏幕顶部往下第 4 px，仍在刘海高度（14）以内。
        let notchY = padding + rim + bezel + 6

        let inNotch = try pixel(in: output, x: screenMidX, y: notchY)
        #expect(inNotch.luminance < 40, "刘海位置应是黑色，实际亮度 \(inNotch.luminance)")

        // 同一行、屏幕左侧（远离刘海）应仍是内容的白。
        let leftOfNotch = try pixel(in: output, x: padding + rim + bezel + 60, y: notchY)
        #expect(leftOfNotch.luminance > 200, "刘海外的内容不该被遮住")
    }

    @Test("刘海之下内容正常显示")
    func contentBelowNotchIsIntact() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        let output = try DeviceFrameComposer.render(content, style: .default)

        // 越过刘海高度之后，屏幕正中应恢复成内容。
        let y = 52 + 8 + 16 + 16 + 12
        let below = try pixel(in: output, x: 52 + 8 + 16 + 500, y: y)
        #expect(below.luminance > 200, "刘海下方应该是内容，实际亮度 \(below.luminance)")
    }

    @Test("屏幕顶部有圆角，底部是直角（真机特征）")
    func screenIsRoundOnTopSquareAtBottom() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let output = try DeviceFrameComposer.render(content, style: style)

        // 屏幕区域：padding 52 + rim 8 起，周围黑边 20。
        let screenTop = 52 + 8
        let screenLeft = 52 + 8
        let screenBottom = screenTop + 20 * 2 + 600   // 屏幕下沿（不含下巴）

        // 顶部左角：因为圆角，紧贴屏幕角的位置应是**背景**（透明），不是黑边。
        let topCorner = try pixel(in: output, x: screenLeft, y: screenTop)
        #expect(topCorner.alpha == 0, "屏幕顶部应是圆角，角落不应被黑边填满")

        // 底部左角：直角，紧贴角落的位置应是黑边（不透明）。
        let bottomCorner = try pixel(in: output, x: screenLeft, y: screenBottom - 1)
        #expect(bottomCorner.alpha == 255, "屏幕底部应是直角，角落被黑边填满")
    }

    @Test("刘海宽度约占屏宽 10%，不是一小块")
    func notchWidthMatchesRealDevice() throws {
        // 实测：真机刘海占屏宽 10.71%。画成 5% 或 20% 都会一眼不像。
        // 内容用纯白，这样深色像素只可能是刘海/黑边，不会和内容混淆。
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let output = try DeviceFrameComposer.render(content, style: style)

        // 取刘海高度中段的一行（避开顶部圆角）。
        let screenTop = 52 + 8
        let y = screenTop + 20 + 10
        var darkRun = 0
        for x in 0..<output.width {
            let p = try pixel(in: output, x: x, y: y)
            if p.alpha == 255, p.luminance < 40 { darkRun += 1 }
        }
        let ratio = Double(darkRun) / Double(output.width)
        // 屏宽 = 1000 + 黑边 40 = 1040；输出宽再加边框与留白 = 1176。
        // 刘海 107u / 1176 ≈ 9.1%，落在 7%–13% 区间。
        #expect(ratio > 0.07 && ratio < 0.13, "刘海宽度占比 \(ratio)，应在 7%–13% 之间")
    }

    // MARK: - 配色

    @Test("银色与深空灰机身可区分")
    func finishesAreDistinguishable() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)

        var silver = DeviceFrameStyle.default
        silver.finish = .silver
        var gray = DeviceFrameStyle.default
        gray.finish = .spaceGray

        let silverOutput = try DeviceFrameComposer.render(content, style: silver)
        let grayOutput = try DeviceFrameComposer.render(content, style: gray)

        // 取机身左侧直边中段：要远离 16u 圆角切口，
        // 否则会采到圆角外的背景，两种配色都读成一样。
        let sampleX = 54
        let sampleY = 52 + 300
        let silverPixel = try pixel(in: silverOutput, x: sampleX, y: sampleY)
        let grayPixel = try pixel(in: grayOutput, x: sampleX, y: sampleY)

        #expect(silverPixel.luminance > grayPixel.luminance + 60, "银色机身明显更亮")
    }

    @Test("渐变背景不透明")
    func gradientBackgroundIsOpaque() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .ocean

        let output = try DeviceFrameComposer.render(content, style: style)
        // 画布左上角（最外层留白内）。
        let corner = try pixel(in: output, x: 2, y: 2)
        #expect(corner.alpha == 255)
    }

    @Test("透明背景四角透明")
    func transparentBackgroundLeavesCornersClear() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false

        let output = try DeviceFrameComposer.render(content, style: style)
        // 关掉阴影时，最外层留白应保持透明（不会因机身路径覆盖到角落）。
        let corner = try pixel(in: output, x: 0, y: 0)
        #expect(corner.alpha == 0)
    }

    @Test("内容不会被上下颠倒")
    func contentIsUpright() throws {
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let content = try makeQuadrantImage()
        let output = try DeviceFrameComposer.render(content, style: style)

        // 内容起点 = 留白 52 + 黑边 10。
        let origin = 52 + 8 + 20
        let quarter = 250
        let topLeft = try pixel(in: output, x: origin + quarter, y: origin + quarter)
        let bottomRight = try pixel(in: output, x: origin + 750, y: origin + 750)

        #expect(topLeft.isNear(red: 0xFF, green: 0x00, blue: 0x00), "左上应是红色")
        #expect(bottomRight.isNear(red: 0xFF, green: 0xFF, blue: 0x00), "右下应是黄色")
    }

    // MARK: - 与窗口壳的互斥

    @Test("全屏来源的壳形态是 MacBook / 仅阴影，不含窗口")
    func fullScreenChromeHasNoWindow() {
        for source in [ScreenshotSource.display, .allDisplays] {
            let options = ScreenshotFrameStyle.allowedChrome(for: source)
            #expect(!options.contains(.window), "\(source) 不该再提供窗口壳")
            #expect(options.contains(.macbook))
            #expect(options.contains(.shadowOnly))
        }
    }

    @Test("区域与长截图不提供 MacBook 机壳")
    func regionAndScrollHaveNoMacbook() {
        for source in [ScreenshotSource.region, .scroll] {
            let options = ScreenshotFrameStyle.allowedChrome(for: source)
            #expect(!options.contains(.macbook), "\(source) 不该出现设备壳")
        }
    }

    @Test("窗口来源只有仅阴影")
    func windowOnlyHasShadow() {
        #expect(ScreenshotFrameStyle.allowedChrome(for: .window) == [.shadowOnly])
    }

    @Test("compose 会把 MacBook 转交给设备壳渲染器")
    func composeRoutesToDeviceRenderer() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = ScreenshotFrameStyle.default
        style.chrome = .macbook

        let viaCompose = try ScreenshotFrameComposer.compose(content, cropRect: nil, style: style)
        let direct = try DeviceFrameComposer.render(
            content,
            style: DeviceFrameStyle.derived(from: style)
        )

        // 两条路径必须得到同一张图，否则预览与导出的尺寸会对不上。
        #expect(viaCompose.width == direct.width)
        #expect(viaCompose.height == direct.height)
    }

    @Test("设备壳样式沿用窗口壳的背景 / 边距 / 阴影")
    func deviceStyleInheritsSharedOptions() {
        var frame = ScreenshotFrameStyle.default
        frame.background = .aurora
        frame.padding = .large
        frame.showsShadow = false

        let device = DeviceFrameStyle.derived(from: frame)
        #expect(device.background == .aurora)
        #expect(device.padding == .large)
        #expect(device.showsShadow == false)
    }

    // MARK: - 辅助

    private func makeSolidImage(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
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
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try makeSolidImage(width: width, height: height, gray: 1)
    }

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
}
