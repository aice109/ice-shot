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
        /// 外机身圆角。
        static let bodyCornerRadius: CGFloat = 16
        /// 屏幕圆角。
        static let screenCornerRadius: CGFloat = 8
        /// 屏幕黑边（机身内沿到屏幕边）。
        static let bezel: CGFloat = 16
        /// 机身边框（屏幕外沿到机身外沿）：让机身比屏幕大一圈，否则黑屏会盖满整块机身。
        static let bodyRim: CGFloat = 8
        /// 刘海宽 / 高。
        static let notchWidth: CGFloat = 56
        static let notchHeight: CGFloat = 16
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

        // 2. 投影 + 机身底
        let bodyPath = CGPath(
            roundedRect: flipped(bodyRect),
            cornerWidth: Metrics.bodyCornerRadius * scale,
            cornerHeight: Metrics.bodyCornerRadius * scale,
            transform: nil
        )
        let palette = palette(for: style.finish)
        context.saveGState()
        if style.showsShadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -24 * scale),
                blur: 60 * scale,
                color: CGColor(gray: 0, alpha: 0.30)
            )
        }
        context.setFillColor(palette.bodyTop)
        context.addPath(bodyPath)
        context.fillPath()
        context.restoreGState()

        // 3. 机身竖直渐变（银 / 深空灰的金属感）
        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        ScreenshotFrameComposer.drawLinearGradient(
            from: CGPoint(x: 0, y: flipped(bodyRect).maxY),
            to: CGPoint(x: 0, y: flipped(bodyRect).minY),
            colors: [palette.bodyTop, palette.bodyBottom],
            in: context
        )
        context.restoreGState()

        // 4. 屏幕底（黑边区域）+ 内容
        let screenPath = CGPath(
            roundedRect: flipped(screenRect),
            cornerWidth: Metrics.screenCornerRadius * scale,
            cornerHeight: Metrics.screenCornerRadius * scale,
            transform: nil
        )
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
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
        // 只圆下角：用一条从两侧下角切起的路径，上沿保持直角贴屏幕边。
        let notchRadius = Metrics.notchHeight * fit / 2
        let notchPath = CGMutablePath()
        let flippedNotch = flipped(notchRect)
        notchPath.move(to: CGPoint(x: flippedNotch.minX, y: flippedNotch.maxY))
        notchPath.addLine(to: CGPoint(x: flippedNotch.minX, y: flippedNotch.minY + notchRadius))
        notchPath.addQuadCurve(
            to: CGPoint(x: flippedNotch.minX + notchRadius, y: flippedNotch.minY),
            control: CGPoint(x: flippedNotch.minX, y: flippedNotch.minY)
        )
        notchPath.addLine(to: CGPoint(x: flippedNotch.maxX - notchRadius, y: flippedNotch.minY))
        notchPath.addQuadCurve(
            to: CGPoint(x: flippedNotch.maxX, y: flippedNotch.minY + notchRadius),
            control: CGPoint(x: flippedNotch.maxX, y: flippedNotch.minY)
        )
        notchPath.addLine(to: CGPoint(x: flippedNotch.maxX, y: flippedNotch.maxY))
        notchPath.closeSubpath()
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(notchPath)
        context.fillPath()
        context.restoreGState()

        // 6. 机身描边：外亮内暗两层，做出金属倒角。
        context.addPath(bodyPath)
        context.setStrokeColor(palette.bodyBorder)
        context.setLineWidth(max(1, scale))
        context.strokePath()

        guard let output = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return output
    }

    /// 机身配色。
    private struct Palette {
        let bodyTop: CGColor
        let bodyBottom: CGColor
        let bodyBorder: CGColor
    }

    private static func palette(for finish: DeviceFrameStyle.Finish) -> Palette {
        switch finish {
        case .silver:
            return Palette(
                bodyTop: color(0xE3E4E6),
                bodyBottom: color(0xC8C9CC),
                bodyBorder: color(0x8E8E93, alpha: 0.35)
            )
        case .spaceGray:
            return Palette(
                bodyTop: color(0x4A4A4E),
                bodyBottom: color(0x2E2E31),
                bodyBorder: color(0x000000, alpha: 0.45)
            )
        }
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
