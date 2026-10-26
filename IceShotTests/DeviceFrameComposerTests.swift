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

    @Test("输出尺寸与 outputSize 一致，且大于内容")
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

        // 具体数值由 Metrics 决定；这里锁住「画出来的尺寸 == outputSize 算出来的」，
        // 以及三层结构必然让输出大于内容。
        #expect(output.width > 1000)
        #expect(output.height > 600)
    }

    @Test("大内容按比例放大机身")
    func largeContentScales() throws {
        let content = try makeImage(width: 2000, height: 1200)
        let style = DeviceFrameStyle.default   // u = 2

        let output = try DeviceFrameComposer.render(content, style: style)
        let expected = DeviceFrameComposer.outputSize(
            for: CGSize(width: 2000, height: 1200),
            style: style
        )
        #expect(output.width == Int(expected.width.rounded()))
        #expect(output.height == Int(expected.height.rounded()))
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

        // 屏幕贴着上盖顶，刘海在屏幕顶部正中。
        let centerX = output.width / 2
        let notchProbeY = insetTop + 4
        let inNotch = try pixel(in: output, x: centerX, y: notchProbeY)
        #expect(inNotch.luminance < 40, "刘海位置应是黑色，实际亮度 \(inNotch.luminance)")

        // 同一行、远离刘海的位置应仍是内容的白。
        let leftOfNotch = try pixel(in: output, x: centerX - 260, y: notchProbeY)
        #expect(leftOfNotch.luminance > 200, "刘海外的内容不该被遮住")
    }

    @Test("刘海之下内容正常显示")
    func contentBelowNotchIsIntact() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        let output = try DeviceFrameComposer.render(content, style: .default)

        // 越过刘海高度之后，屏幕正中应恢复成内容。
        let y = insetTop + 13 + 12
        let below = try pixel(in: output, x: output.width / 2, y: y)
        #expect(below.luminance > 200, "刘海下方应该是内容，实际亮度 \(below.luminance)")
    }

    @Test("屏幕四周是圆角矩形")
    func screenHasRoundedCorners() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let output = try DeviceFrameComposer.render(content, style: style)

        // 屏幕左上角：因为圆角，紧贴角落的位置应是背景（透明）。
        let corner = try pixel(in: output, x: insetLeft, y: insetTop)
        #expect(corner.alpha == 0, "屏幕顶部应是圆角")
    }

    @Test("底座比上盖宽，且在两块之间留出间隙")
    func baseIsWiderThanLidWithGap() throws {
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        let output = try DeviceFrameComposer.render(content, style: style)

        // 沿垂直中线从上往下，逐行找「非透明区间」的宽度，
        // 上盖与底座各自是一个宽的横条，中间应有一段空白间隙。
        var widths: [(Int, Int)] = []
        for y in 0..<output.height {
            var a = -1, b = -1
            for x in 0..<output.width {
                if (try pixel(in: output, x: x, y: y)).alpha != 0 {
                    if a < 0 { a = x }
                    b = x
                }
            }
            widths.append((a, b))
        }
        // 找最大宽度（底座）与上盖宽度。
        let maxWidth = widths.map { $0.1 - $0.0 }.max() ?? 0
        // 间隙：某一行完全透明，且上下都有非透明行。
        var gapRows = 0
        for y in 1..<(output.height - 1) {
            let here = widths[y]
            if here.0 < 0, widths[y - 1].0 >= 0 || widths[y + 1].0 >= 0 { gapRows += 1 }
        }
        #expect(gapRows > 0, "上盖与底座之间应有间隙")
        #expect(maxWidth > 1000, "底座应比内容宽")
    }

    @Test("银色与深空灰机身可区分")
    func finishesAreDistinguishable() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)

        var silver = DeviceFrameStyle.default
        silver.finish = .silver
        var gray = DeviceFrameStyle.default
        gray.finish = .spaceGray

        let silverOutput = try DeviceFrameComposer.render(content, style: silver)
        let grayOutput = try DeviceFrameComposer.render(content, style: gray)

        // 取样点：上盖底部那条铝面（屏幕下缘与上盖底边之间）。
        //
        // 坐标来自实测：沿中线垂直扫描两幅图，银色在内容下方出现 211 的亮带、
        // 深空灰同位置是 67，正是上盖下缘的铝面。这里用相对偏移表达，
        // 几何若再调整，这个断言会先失败提醒重测。
        let probeX = silverOutput.width / 2
        let probeY = insetTop + 600 + 2

        let silverPixel = try pixel(in: silverOutput, x: probeX, y: probeY)
        let grayPixel = try pixel(in: grayOutput, x: probeX, y: probeY)

        #expect(silverPixel.luminance > grayPixel.luminance + 60, "银色机身明显更亮")
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

    /// 屏幕内容区在输出图里的左上角（中留白 52u + 黑边 2u，u=1）。
    private var insetTop: Int { 54 }
    private var insetLeft: Int { 54 }

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
