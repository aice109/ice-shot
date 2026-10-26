import CoreGraphics
import Foundation

/// 把一张整屏截图渲染成「一台正在显示它的 MacBook」。
///
/// 纯 CoreGraphics，不依赖 SwiftUI / AppKit，与 `ScreenshotFrameComposer` 同一条理由：
/// 预览与导出共用同一个渲染器，避免「预览好看、导出不一样」。
///
/// 几何分三层：**内容 → 屏幕 → 机身**。窗口壳只有前两层的一部分（内容 + 一圈留白），
/// 这里多出机身与刘海，因此不复用它的布局代码，只复用背景渐变与投影参数。
nonisolated enum DeviceFrameComposer {
    /// 以“内容宽 1000 px”为 1u 基准。与窗口壳同一套换算，便于两个渲染器互相对齐。
    private static let contentWidthForUnit: CGFloat = 1000

    /// 各比例的几何值（单位 u）。集中放在一处，改视觉规格只动这里。
    ///
    /// 这些值是对着真机观感调的，不是按毫米精确换算：
    /// 真机 14" 的黑边约 3.5 mm，但在 1000 px 宽的内容上如果按真实比例画只有 6 px，
    /// 导出图里几乎看不见，成品像「一张图贴在白框里」而不是一台电脑。
    /// 所以黑边、刘海都适当放大，优先保证观感识别度。
    private enum Metrics {
        /// 外机身圆角。真机外沿很圆。
        static let bodyCornerRadius: CGFloat = 30
        /// 屏幕圆角。
        ///
        /// **只有上面两个角是圆的**——最新 MacBook 的屏幕是「上圆下方」。
        /// 必须**明显大于黑边厚度**（bezel 16），否则圆角整段被黑边吃掉、肉眼看不出来。
        /// 取 34，扣掉黑边后仍有约 18u 的可见弧度。
        static let screenCornerTop: CGFloat = 34
        /// 屏幕黑边（机身内沿到屏幕边）。
        static let bezel: CGFloat = 16
        /// 机身边框（屏幕外沿到机身外沿）：让机身比屏幕大一圈，否则黑屏会盖满整块机身。
        static let bodyRim: CGFloat = 8
        /// 刘海宽 / 高。
        ///
        /// 真机刘海约占屏宽 11%～12%。第一版画 56u 太小，像个小方标签；
        /// 取 116×24u，配四角圆角，才像一次真正的挖孔。
        static let notchWidth: CGFloat = 116
        static let notchHeight: CGFloat = 24
        /// 刘海四角圆角半径（相对高度，约 0.45 倍）。
        static var notchCorner: CGFloat { notchHeight * 0.45 }
        /// 下巴（屏幕下沿到机身下沿）。
        static let chin: CGFloat = 22
    }

    /// 渲染。
    ///
    /// - Parameters:
    ///   - content: 已经渲染好标注、并且**已经按选区裁剪**的整屏内容图。
    ///   - style: 设备壳样式。
    ///   - maximumDimension: 预览用，长边不超过该值；导出时不传。
    static func render(
        _ content: CGImage,
        style: DeviceFrameStyle,
        maximumDimension: Int? = nil
    ) throws -> CGImage {
        guard content.width > 0, content.height > 0 else {
            throw CaptureError.encodingFailed
        }

        // 以内容宽度定 1u；太小的图限制下限，避免机身占掉半张图。
        let unit = min(max(CGFloat(content.width) / contentWidthForUnit, 0.8), 2.0)

        let bezel = Metrics.bezel * unit
        let notchWidth = Metrics.notchWidth * unit
        let notchHeight = Metrics.notchHeight * unit
        let chin = Metrics.chin * unit
        let rim = Metrics.bodyRim * unit
        let paddingBase = style.padding.baseValue * unit

        // 三层：内容 → 屏幕（内容 + 黑边）→ 机身（屏幕 + 边框 + 下下巴）。
        let screenWidthBase = CGFloat(content.width) + bezel * 2
        let screenHeightBase = CGFloat(content.height) + bezel * 2
        let bodyWidthBase = screenWidthBase + rim * 2
        let bodyHeightBase = screenHeightBase + rim * 2 + chin
        let outputWidthBase = bodyWidthBase + paddingBase * 2
        let outputHeightBase = bodyHeightBase + paddingBase * 2

        var fit: CGFloat = 1
        if let maximumDimension, maximumDimension > 0 {
            let longest = max(outputWidthBase, outputHeightBase)
            if longest > CGFloat(maximumDimension) {
                fit = CGFloat(maximumDimension) / longest
            }
        }

        let scale = unit * fit
        let scaledBezel = bezel * fit
        let scaledRim = rim * fit
        let scaledPadding = paddingBase * fit
        let screenSize = CGSize(
            width: screenWidthBase * fit,
            height: screenHeightBase * fit
        )
        let bodySize = CGSize(
            width: bodyWidthBase * fit,
            height: bodyHeightBase * fit
        )
        let outputSize = CGSize(
            width: outputWidthBase * fit,
            height: outputHeightBase * fit
        )
        let pixelWidth = max(1, Int(outputSize.width.rounded()))
        let pixelHeight = max(1, Int(outputSize.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.encodingFailed
        }

        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // 布局量全按左上原点算，绘制时翻成 CGContext 的左下原点。
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX,
                y: CGFloat(pixelHeight) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }

        let bodyRect = CGRect(
            x: scaledPadding,
            y: scaledPadding,
            width: bodySize.width,
            height: bodySize.height
        )
        // screenRect 是**整个屏幕（含黑边）**；内容在它内部再居中。
        // 曾经把这里写成「已扣黑边的内容区」，结果黑边从未被填充，
        // 机身和内容直接相接，成品看起来像「一张图贴在白框里」。
        let screenRect = CGRect(
            x: bodyRect.minX + scaledRim,
            y: bodyRect.minY + scaledRim,
            width: screenSize.width,
            height: screenSize.height
        )

        // 1. 背景
        if let gradient = ScreenshotFramePalette.gradient(for: style.background.shared) {
            ScreenshotFrameComposer.drawLinearGradient(
                from: CGPoint(x: 0, y: CGFloat(pixelHeight)),
                to: CGPoint(x: CGFloat(pixelWidth), y: 0),
                colors: [gradient.start, gradient.end],
                in: context
            )
        }

        // 2. 机身形：投影 + 填充 + 金属渐变
        let bodyPath = CGPath(
            roundedRect: flipped(bodyRect),
            cornerWidth: Metrics.bodyCornerRadius * scale,
            cornerHeight: Metrics.bodyCornerRadius * scale,
            transform: nil
        )
        let palette = palette(for: style.finish)

        // 2a. 落影。真机照片里机身和桌面之间有明显分离，
        //     所以模糊更大、向下偏移更明显，而不是轻轻一圈。
        context.saveGState()
        if style.showsShadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -18 * scale),
                blur: 46 * scale,
                color: CGColor(gray: 0, alpha: 0.38)
            )
            // 第二层更散、更淡，做出环境光遮蔽的柔和过渡。
            context.setShadow(
                offset: CGSize(width: 0, height: -30 * scale),
                blur: 90 * scale,
                color: CGColor(gray: 0, alpha: 0.18)
            )
        }
        context.setFillColor(palette.upper)
        context.addPath(bodyPath)
        context.fillPath()
        context.restoreGState()

        // 2b. 金属竖直渐变：上缘受光、下缘转暗。
        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        drawMetalGradient(
            in: context,
            rect: flipped(bodyRect),
            palette: palette
        )
        context.restoreGState()

        // 4. 屏幕底（黑边区域）+ 内容
        //
        //    屏幕是「上圆下方」：只有左上、右上两角是圆角，下面两角是直角。
        //    这是最新 MacBook 的真实特征，四角全圆会显得像老款 iPad。
        let screenPath = topRoundedPath(
            flipped(screenRect),
            topRadius: Metrics.screenCornerTop * scale
        )
        // 屏幕玻璃底：真机关屏时是极深的灰，不是纯黑；纯黑会让边界过于生硬。
        context.saveGState()
        context.setFillColor(palette.glass)
        context.addPath(screenPath)
        context.fillPath()

        // 内容按屏幕圆角裁切，四角才不会溢出到机身上。
        context.addPath(screenPath)
        context.clip()
        // 内容在屏幕内居中：四周各让出 bezel。
        let contentRect = CGRect(
            x: screenRect.minX + scaledBezel,
            y: screenRect.minY + scaledBezel,
            width: screenRect.width - scaledBezel * 2,
            height: screenRect.height - scaledBezel * 2
        )
        context.draw(content, in: flipped(contentRect))
        context.restoreGState()

        // 5. 刘海：从**内容区上沿**往下长出，上沿贴黑边。
        //    真机的刘海就是从屏幕玻璃顶边长出来的，不是悬在中间；
        //    它压在内容上，因此必须先画内容再画它（顺序见下）。
        let contentTop = screenRect.minY + scaledBezel
        let notchRect = CGRect(
            x: screenRect.midX - notchWidth * fit / 2,
            y: contentTop,
            width: notchWidth * fit,
            height: notchHeight * fit
        )
        // 真机刘海（2021 起）是「上沿平直、两侧以圆角收进屏幕」的形状：
        // 两个下角用三次贝塞尔，比二次曲线更接近连续的曲率过渡；
        // 四角再加一点点外圆角，避免两条边在屏幕上沿交接处出现尖角。
        let nRect = flipped(notchRect)
        // 四角同半径：真机刘海是圆角矩形挖孔，不是「上直角、下半圆」。
        let corner = Metrics.notchCorner * scale
        let topCorner = corner
        // 三次贝塞尔近似 1/4 圆的控制点系数。
        let k: CGFloat = 0.5523

        let notchPath = CGMutablePath()
        // 从上沿左侧开始（受 topCorner 内缩）
        notchPath.move(to: CGPoint(x: nRect.minX + topCorner, y: nRect.maxY))
        // 上左小圆角 → 左直边
        notchPath.addCurve(
            to: CGPoint(x: nRect.minX, y: nRect.maxY - topCorner),
            control1: CGPoint(x: nRect.minX + topCorner * (1 - k), y: nRect.maxY),
            control2: CGPoint(x: nRect.minX, y: nRect.maxY - topCorner * (1 - k))
        )
        // 左直边下行到圆角起点
        notchPath.addLine(to: CGPoint(x: nRect.minX, y: nRect.minY + corner))
        // 左下大圆角
        notchPath.addCurve(
            to: CGPoint(x: nRect.minX + corner, y: nRect.minY),
            control1: CGPoint(x: nRect.minX, y: nRect.minY + corner * (1 - k)),
            control2: CGPoint(x: nRect.minX + corner * (1 - k), y: nRect.minY)
        )
        // 底边
        notchPath.addLine(to: CGPoint(x: nRect.maxX - corner, y: nRect.minY))
        // 右下大圆角
        notchPath.addCurve(
            to: CGPoint(x: nRect.maxX, y: nRect.minY + corner),
            control1: CGPoint(x: nRect.maxX - corner * (1 - k), y: nRect.minY),
            control2: CGPoint(x: nRect.maxX, y: nRect.minY + corner * (1 - k))
        )
        // 右直边上行
        notchPath.addLine(to: CGPoint(x: nRect.maxX, y: nRect.maxY - topCorner))
        // 上右小圆角
        notchPath.addCurve(
            to: CGPoint(x: nRect.maxX - topCorner, y: nRect.maxY),
            control1: CGPoint(x: nRect.maxX, y: nRect.maxY - topCorner * (1 - k)),
            control2: CGPoint(x: nRect.maxX - topCorner * (1 - k), y: nRect.maxY)
        )
        notchPath.closeSubpath()
        context.saveGState()
        // 刘海与玻璃同色：真机刘海是一块连续的黑色挖孔，不是贴上去的黑块。
        context.setFillColor(palette.glass)
        context.addPath(notchPath)
        context.fillPath()
        // 极细的暗描边，让刘海和菜单栏之间有可辨的接缝。
        context.addPath(notchPath)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
        context.setLineWidth(max(0.5, 0.6 * scale))
        context.strokePath()
        context.restoreGState()

        // 6. 机身外沿高光 + 内沿阴影，做出金属倒角与层次。
        //
        //    这两道是「像 MacBook」的关键：没有它们，机身就是一块纯色板，
        //    圆角在视觉上会读成硬直角。
        context.saveGState()
        // 直接沿机身路径描边即可：描边居中在路径上，一半在内一半在外，
        // 外半被画布裁掉、内半留在机身上，天然形成贴着外沿的高光。
        //
        // 之前另外造了一条「内缩路径」，但圆角半径没同步缩，
        // 两者不同心，转角处就露出错位的白边。
        context.addPath(bodyPath)
        context.setStrokeColor(palette.rimHighlight)
        context.setLineWidth(max(1, 1.2 * scale))
        context.strokePath()
        context.restoreGState()

        // 内沿阴影：贴着屏幕（黑边区）外圈压一道暗边，把屏幕「嵌」进机身。
        context.saveGState()
        let screenFrame = screenRect.insetBy(dx: -1.2 * scale, dy: -1.2 * scale)
        let innerPath = CGPath(
            roundedRect: flipped(screenFrame),
            cornerWidth: Metrics.screenCornerTop * scale + 1.2 * scale,
            cornerHeight: Metrics.screenCornerTop * scale + 1.2 * scale,
            transform: nil
        )
        context.addPath(innerPath)
        context.setStrokeColor(palette.innerShade)
        context.setLineWidth(max(1, 1.6 * scale))
        context.strokePath()
        context.restoreGState()

        guard let output = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return output
    }

    /// 机身配色。
    ///
    /// 真机是阳极氧化铝：不是单一填充色，而是「上缘受光 → 中间平缓 → 下缘转暗」的柔和渐变，
    /// 再加一道 1u 亮高光勾外沿、一道内阴影压内沿。
    /// 只填一个纯色会让机身和背景糊成一片，圆角看起来也就「硬」了。
    private struct Palette {
        /// 竖直渐变的四个停靠点（从上到下）。
        let highlight: CGColor
        let upper: CGColor
        let lower: CGColor
        let shade: CGColor
        /// 外沿高光。
        let rimHighlight: CGColor
        /// 内沿阴影（机身与黑边之间）。
        let innerShade: CGColor
        /// 屏幕玻璃底色。
        let glass: CGColor
    }

    private static func palette(for finish: DeviceFrameStyle.Finish) -> Palette {
        switch finish {
        case .silver:
            return Palette(
                highlight: color(0xF7F8F9),
                upper: color(0xE8E9EB),
                lower: color(0xD2D3D6),
                shade: color(0xBFC0C4),
                // 浅银底上用纯白会过曝成一道白边，降到 0.55 并略带暖调。
                rimHighlight: color(0xFFFFFF, alpha: 0.55),
                innerShade: color(0x5A5A5F, alpha: 0.22),
                glass: color(0x16171A)
            )
        case .spaceGray:
            return Palette(
                highlight: color(0x6C6C72),
                upper: color(0x515157),
                lower: color(0x3A3A3F),
                shade: color(0x2A2A2E),
                rimHighlight: color(0x9A9AA0, alpha: 0.55),
                innerShade: color(0x000000, alpha: 0.55),
                glass: color(0x0E0F11)
            )
        }
    }

    /// 四点竖直渐变，做出阳极氧化铝的柔和受光。
    ///
    /// 用四个停靠点而不是两端：真机机身的上缘高光和下缘阴影都只占很小一段，
    /// 中间是大片平缓过渡，两端渐变会显得像塑料。
    private static func drawMetalGradient(
        in context: CGContext,
        rect: CGRect,
        palette: Palette
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            colors: [
                palette.highlight,
                palette.upper,
                palette.lower,
                palette.shade,
            ] as CFArray,
            locations: [0, 0.18, 0.62, 1]
        ) else {
            return
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.minX, y: rect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// 顶部两角圆、底部两角直角的矩形路径。
    ///
    /// 用三次贝塞尔（0.5523 系数）近似 1/4 圆；这个尺寸下与真机的差别不可见。
    /// 注意入参 rect 已是**翻转后**的坐标（左下原点），所以「顶部」是 maxY 一侧。
    private static func topRoundedPath(_ rect: CGRect, topRadius radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let k: CGFloat = 0.5523
        let path = CGMutablePath()
        // 左下（直角）
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // 左侧上行到左上角圆角起点
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        // 左上圆角
        path.addCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.maxY - r * (1 - k)),
            control2: CGPoint(x: rect.minX + r * (1 - k), y: rect.maxY)
        )
        // 上边
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        // 右上圆角
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - r * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - r * (1 - k))
        )
        // 右侧下行到右下（直角）
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 输出尺寸（导出用）。单测与预览 sizing 共用，避免两处各算一遍。
    static func outputSize(
        for contentPixelSize: CGSize,
        style: DeviceFrameStyle
    ) -> CGSize {
        let unit = min(max(contentPixelSize.width / contentWidthForUnit, 0.8), 2.0)
        let bezel = Metrics.bezel * unit
        let chin = Metrics.chin * unit
        let rim = Metrics.bodyRim * unit
        let padding = style.padding.baseValue * unit
        let bodyWidth = contentPixelSize.width + (bezel + rim) * 2
        let bodyHeight = contentPixelSize.height + (bezel + rim) * 2 + chin
        return CGSize(
            width: bodyWidth + padding * 2,
            height: bodyHeight + padding * 2
        )
    }
}
