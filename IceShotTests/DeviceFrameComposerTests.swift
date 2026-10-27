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

    @Test("机身比例对齐 14 吋 MacBook Pro，且不随内容像素尺寸漂移")
    func lidMatchesMacBookPro14Proportions() throws {
        // 1000×649.5 是 3024×1964 的等比缩小；真机 312.6×214.7 mm 的宽高比约 1.456。
        let ratioAtUnit = DeviceFrameComposer.lidSize(
            for: CGSize(width: 1000, height: 649.5)
        )
        let ratio = ratioAtUnit.width / ratioAtUnit.height
        #expect(abs(ratio - 1.456) < 0.01, "机身宽高比应接近真机，实际 \(ratio)")

        // Retina 全屏截图是 3024 px 宽；比例必须与 1000u 时一致，
        // 否则黑边和刘海会被相对压小。
        let retina = DeviceFrameComposer.lidSize(for: CGSize(width: 3024, height: 1964))
        let retinaRatio = retina.width / retina.height
        #expect(abs(retinaRatio - ratio) < 0.005, "Retina 内容不该改变机身比例，实际 \(retinaRatio)")
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

        // 刘海在屏幕顶部正中。
        let centerX = output.width / 2
        let notchProbeY = contentTop + 6
        let inNotch = try pixel(in: output, x: centerX, y: notchProbeY)
        #expect(inNotch.luminance < 40, "刘海位置应是黑色，实际亮度 \(inNotch.luminance)")

        // 同一行、远离刘海的位置应仍是内容的白。
        let leftOfNotch = try pixel(in: output, x: centerX - 220, y: notchProbeY)
        #expect(leftOfNotch.luminance > 200, "刘海外的内容不该被遮住")
    }

    @Test("刘海可以跟随来源菜单栏高度：外接屏上不再压过状态栏")
    func notchFollowsSourceMenuBar() throws {
        // 4K 外接屏：菜单栏 31pt × 2 = 62px，截图内容宽 3840px。
        let content = try makeSolidImage(width: 3840, height: 2160, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let u: CGFloat = 3.84
        let output = try DeviceFrameComposer.render(
            content,
            style: style,
            notchHeightInUnits: 62 * 1000 / 3840
        )

        // 内容区上沿：留白 52 + 铝框 5.5 + 上黑边 11.5（u）。
        let contentTop = (52 + 5.5 + 11.5) * u
        // 避开居中摄像头，在刘海内部偏左取一列，找「黑 → 白」的边界。
        let probeX = output.width / 2 - 100
        var lastNotchRow = contentTop
        for y in Int(contentTop)..<Int(contentTop + 200) {
            let probe = try pixel(in: output, x: probeX, y: y)
            guard probe.luminance < 60 else { break }
            lastNotchRow = CGFloat(y)
        }
        let notchHeight = lastNotchRow - contentTop + 1
        #expect(
            abs(notchHeight - 62) <= 2,
            "刘海应与 62px 菜单栏对齐，实际 \(notchHeight) px"
        )
    }

    @Test("刘海之下内容正常显示")
    func contentBelowNotchIsIntact() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        let output = try DeviceFrameComposer.render(content, style: .default)

        // 越过刘海高度（21u）之后，屏幕正中应恢复成内容。
        let y = contentTop + 21 + 12
        let below = try pixel(in: output, x: output.width / 2, y: y)
        #expect(below.luminance > 200, "刘海下方应该是内容，实际亮度 \(below.luminance)")
    }

    @Test("玻璃四角都是圆角：机身与玻璃同心，铝框在转角处不断开")
    func glassIsRoundedAtAllFourCorners() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let output = try DeviceFrameComposer.render(content, style: style)

        // 玻璃中部（上黑边）的取样点：作为「黑色玻璃」的基准色。
        let glassProbe = try pixel(in: output, x: output.width / 2 - 300, y: glassTop + 5)
        #expect(glassProbe.luminance < 40, "黑边应是深色玻璃，实际亮度 \(glassProbe.luminance)")

        // 玻璃四角都必须是圆的：在距左边 10u、紧贴上/下沿的位置，
        // 方角玻璃会盖到这里（黑），圆角玻璃则让了出来（露出铝框）。
        let topLeft = try pixel(in: output, x: glassLeft + 10, y: glassTop + 1)
        let bottomLeft = try pixel(in: output, x: glassLeft + 10, y: glassBottom - 1)
        for probe in [topLeft, bottomLeft] {
            #expect(probe.alpha > 200, "圆角处应仍是机身铝框，不该变成透明")
            #expect(probe.luminance > 100, "玻璃圆角外侧应是浅色铝框，实际亮度 \(probe.luminance)")
        }
    }

    @Test("有效显示区上圆下方：上面两角被面板圆角切掉，下面两角是直角")
    func panelIsRoundOnTopAndSquareAtBottom() throws {
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let output = try DeviceFrameComposer.render(content, style: style)

        // 面板上角：贴着内容区左上角的内侧，应在圆角之外，露出黑色玻璃。
        let topCorner = try pixel(in: output, x: contentLeft + 2, y: contentTop + 2)
        #expect(topCorner.luminance < 60, "内容区上角应被面板圆角切掉，实际亮度 \(topCorner.luminance)")

        // 面板下角：真机面板下角是直角，紧贴角落仍是内容的白。
        let bottomCorner = try pixel(in: output, x: contentLeft + 2, y: contentBottom - 2)
        #expect(bottomCorner.luminance > 200, "内容区下角应是直角，实际亮度 \(bottomCorner.luminance)")
    }

    @Test("机身是单层，内部没有透明缝隙，且下巴明显比上黑边宽")
    func lidIsSingleLayerWithWideChin() throws {
        var style = DeviceFrameStyle.default
        style.background = .transparent
        style.showsShadow = false
        let content = try makeSolidImage(width: 1000, height: 600, gray: 1)
        let output = try DeviceFrameComposer.render(content, style: style)

        // 沿远离刘海的一列从上往下扫描。
        let column = 300
        var opaqueRows: [Int] = []
        var whiteRows: [Int] = []
        for y in 0..<output.height {
            let probe = try pixel(in: output, x: column, y: y)
            if probe.alpha > 200 { opaqueRows.append(y) }
            if probe.luminance > 245 { whiteRows.append(y) }
        }
        let firstOpaque = try #require(opaqueRows.first)
        let lastOpaque = try #require(opaqueRows.last)
        let firstWhite = try #require(whiteRows.first)
        let lastWhite = try #require(whiteRows.last)

        // 单层：从机身上沿到机身下沿之间不允许再出现透明行。
        #expect(opaqueRows.count == lastOpaque - firstOpaque + 1, "机身内部不该有透明缝隙")

        // 上侧 = 铝框 + 上黑边；下侧 = 下巴黑边 + 铝框。
        let topRun = firstWhite - firstOpaque
        let bottomRun = lastOpaque - lastWhite
        #expect(topRun > 8, "上侧应有铝框与黑边，实际 \(topRun) px")
        #expect(bottomRun > topRun * 2, "下巴应明显比上黑边宽：上 \(topRun) px / 下 \(bottomRun) px")
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

        // 取样点：机身左侧铝框中段。远离玻璃与圆角，两种配色都是金属面。
        let probeX = glassLeft - 3
        let probeY = silverOutput.height / 2

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

        // 内容起点 = 留白 52 + 铝框 5.5 + 上黑边 11.5，u = 1。
        let origin = contentLeft
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

    // 以下坐标按「内容 1000×600 px、中留白 52u、u = 1」的默认样式换算，
    // 并与 `DeviceFrameComposer` 的 Metrics 对照：铝框 5.5、上黑边 11.5、下巴 38。
    /// 玻璃（含黑边）外沿：留白 52 + 铝框 5.5。
    private var glassTop: Int { 58 }
    private var glassLeft: Int { 58 }
    /// 玻璃下沿：内容 600 + 上黑边 11.5 + 下巴 38，再 + 留白 52。
    private var glassBottom: Int { 707 }
    /// 内容区左上角：玻璃 + 上黑边 11.5u。
    private var contentTop: Int { 69 }
    private var contentLeft: Int { 69 }
    private var contentBottom: Int { 669 }

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
