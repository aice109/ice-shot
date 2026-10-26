import CoreGraphics
import CoreText
import Foundation

/// 把一张内容图渲染成带 macOS 窗口壳的成品图。
///
/// 纯 CoreGraphics + CoreText，不依赖 SwiftUI，也不依赖 AppKit。
/// 这样同一个渲染器可以同时服务 popover 预览和最终导出，不会出现「预览好看、导出不一样」。
nonisolated enum ScreenshotFrameComposer {
    /// - Parameters:
    ///   - content: 已经渲染好标注、并且**已经按选区裁剪**的内容图。
    ///   - style: 壳样式。
    ///   - maximumDimension: 预览用。给定时按比例缩小整张成品图，长边不超过该值；
    ///     导出时不传，保持内容原始像素尺寸。
    static func render(
        _ content: CGImage,
        style: ScreenshotFrameStyle,
        maximumDimension: Int? = nil
    ) throws -> CGImage {
        guard content.width > 0, content.height > 0 else {
            throw CaptureError.encodingFailed
        }

        let appearance = resolveAppearance(style: style, content: content)
        let theme = ScreenshotFramePalette.theme(for: appearance)

        // 以 1000 px 宽内容为 1u；太小的图限制下限，避免标题栏占掉半张图。
        let unit = min(max(CGFloat(content.width) / 1000, 0.8), 2.0)
        let titleBarBase: CGFloat = style.chrome == .window ? 28 * unit : 0
        let paddingBase = style.padding.baseValue * unit
        let outputWidthBase = CGFloat(content.width) + paddingBase * 2
        let outputHeightBase = CGFloat(content.height) + titleBarBase + paddingBase * 2

        var fit: CGFloat = 1
        if let maximumDimension, maximumDimension > 0 {
            let longestSide = max(outputWidthBase, outputHeightBase)
            if longestSide > CGFloat(maximumDimension) {
                fit = CGFloat(maximumDimension) / longestSide
            }
        }

        let scale = unit * fit
        let contentSize = CGSize(
            width: CGFloat(content.width) * fit,
            height: CGFloat(content.height) * fit
        )
        let titleBarHeight = titleBarBase * fit
        let padding = paddingBase * fit
        let windowSize = CGSize(
            width: contentSize.width,
            height: contentSize.height + titleBarHeight
        )
        let outputSize = CGSize(
            width: windowSize.width + padding * 2,
            height: windowSize.height + padding * 2
        )
        let pixelWidth = max(1, Int(outputSize.width.rounded()))
        let pixelHeight = max(1, Int(outputSize.height.rounded()))
        let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

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

        // 坐标换算：布局量全部按左上原点算，绘制时翻成 CGContext 的左下原点。
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX,
                y: CGFloat(pixelHeight) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
        func flippedY(_ y: CGFloat) -> CGFloat {
            CGFloat(pixelHeight) - y
        }

        let windowRect = CGRect(
            x: padding,
            y: padding,
            width: windowSize.width,
            height: windowSize.height
        )
        let cornerRadius = min(12 * scale, min(windowRect.width, windowRect.height) / 4)
        let windowPath = CGPath(
            roundedRect: flipped(windowRect),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // 1. 背景
        if let gradient = ScreenshotFramePalette.gradient(for: style.background) {
            drawLinearGradient(
                from: CGPoint(x: 0, y: CGFloat(pixelHeight)),
                to: CGPoint(x: CGFloat(pixelWidth), y: 0),
                colors: [gradient.start, gradient.end],
                in: context
            )
        }

        // 2. 投影 + 窗体底
        context.saveGState()
        if style.showsShadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -16 * scale),
                blur: 40 * scale,
                color: CGColor(gray: 0, alpha: 0.28)
            )
        }
        context.setFillColor(theme.body)
        context.addPath(windowPath)
        context.fillPath()
        context.restoreGState()

        // 3. 窗体内部：标题栏、内容、交通灯、标题
        context.saveGState()
        context.addPath(windowPath)
        context.clip()

        if style.chrome == .window {
            let titleBarRect = CGRect(
                x: windowRect.minX,
                y: windowRect.minY,
                width: windowRect.width,
                height: titleBarHeight
            )
            context.saveGState()
            context.clip(to: flipped(titleBarRect))
            drawLinearGradient(
                from: CGPoint(x: 0, y: flippedY(windowRect.minY)),
                to: CGPoint(x: 0, y: flippedY(windowRect.minY + titleBarHeight)),
                colors: [theme.titleBarTop, theme.titleBarBottom],
                in: context
            )
            context.restoreGState()

            let separatorRect = CGRect(
                x: windowRect.minX,
                y: windowRect.minY + titleBarHeight - 0.5 * scale,
                width: windowRect.width,
                height: 0.5 * scale
            )
            context.setFillColor(theme.separator)
            context.fill(flipped(separatorRect))
        }

        let contentRect = CGRect(
            x: windowRect.minX,
            y: windowRect.minY + titleBarHeight,
            width: contentSize.width,
            height: contentSize.height
        )
        context.draw(content, in: flipped(contentRect))

        if style.chrome == .window {
            drawTrafficLights(
                in: context,
                windowRect: windowRect,
                titleBarHeight: titleBarHeight,
                scale: scale,
                pixelSize: pixelSize
            )
            drawTitle(
                style.title,
                in: context,
                windowRect: windowRect,
                titleBarHeight: titleBarHeight,
                scale: scale,
                pixelSize: pixelSize,
                color: theme.title
            )
        }

        context.restoreGState()

        // 4. 外描边
        context.addPath(windowPath)
        context.setStrokeColor(theme.border)
        context.setLineWidth(max(1, scale))
        context.strokePath()

        guard let output = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return output
    }

    // MARK: - 外观

    /// 自动外观：取截图顶部 1/8 的平均亮度。
    ///
    /// 只看顶部而不是整张图：窗口标题栏通常和内容顶部更接近，整图平均容易被大片深色正文带偏。
    private static func resolveAppearance(
        style: ScreenshotFrameStyle,
        content: CGImage
    ) -> ScreenshotFrameStyle.Appearance {
        switch style.appearance {
        case .light, .dark:
            return style.appearance
        case .automatic:
            return topBandLuminance(content) >= 0.55 ? .light : .dark
        }
    }

    private static func topBandLuminance(_ image: CGImage) -> CGFloat {
        let bandHeight = max(1, image.height / 8)
        guard let band = image.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: bandHeight
        )) else {
            return 0.5
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0.5
        }
        context.interpolationQuality = .medium
        context.draw(band, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0 else { return 0.5 }
        let red = CGFloat(pixel[0]) / 255 / alpha
        let green = CGFloat(pixel[1]) / 255 / alpha
        let blue = CGFloat(pixel[2]) / 255 / alpha
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    // MARK: - 绘制细节

    private static func drawLinearGradient(
        from start: CGPoint,
        to end: CGPoint,
        colors: [CGColor],
        in context: CGContext
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        ) else {
            return
        }
        context.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func drawTrafficLights(
        in context: CGContext,
        windowRect: CGRect,
        titleBarHeight: CGFloat,
        scale: CGFloat,
        pixelSize: CGSize
    ) {
        let diameter = 12 * scale
        let spacing = 8 * scale
        let leading = 20 * scale
        let centerY = pixelSize.height - (windowRect.minY + titleBarHeight / 2)
        var centerX = windowRect.minX + leading + diameter / 2

        for light in [
            ScreenshotFramePalette.close,
            ScreenshotFramePalette.minimize,
            ScreenshotFramePalette.zoom,
        ] {
            let rect = CGRect(
                x: centerX - diameter / 2,
                y: centerY - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.setFillColor(light.fill)
            context.fillEllipse(in: rect)
            context.setStrokeColor(light.stroke)
            context.setLineWidth(max(0.5, 0.5 * scale))
            context.strokeEllipse(in: rect.insetBy(dx: 0.25 * scale, dy: 0.25 * scale))
            centerX += diameter + spacing
        }
    }

    private static func drawTitle(
        _ rawTitle: String,
        in context: CGContext,
        windowRect: CGRect,
        titleBarHeight: CGFloat,
        scale: CGFloat,
        pixelSize: CGSize,
        color: CGColor
    ) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, titleBarHeight > 0 else { return }

        // 交通灯组宽 = 3 × 12u + 2 × 8u = 52u；左边距 20u；再留 12u 呼吸。
        let sideReserve = 84 * scale
        let availableWidth = windowRect.width - sideReserve * 2
        guard availableWidth > 40 * scale else { return }

        let fontSize = max(9, 13 * scale)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil,
            title as CFString,
            attributes as CFDictionary
        ) else {
            return
        }

        let line = CTLineCreateWithAttributedString(attributed)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let drawnLine: CTLine
        if lineWidth > availableWidth {
            let ellipsis = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(
                    nil,
                    "…" as CFString,
                    attributes as CFDictionary
                )!
            )
            drawnLine = CTLineCreateTruncatedLine(
                line,
                Double(availableWidth),
                .end,
                ellipsis
            ) ?? line
        } else {
            drawnLine = line
        }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(
            drawnLine,
            &ascent,
            &descent,
            &leading
        ))
        let centerY = pixelSize.height - (windowRect.minY + titleBarHeight / 2)
        let baseline = centerY - (ascent - descent) / 2
        context.textPosition = CGPoint(
            x: windowRect.midX - width / 2,
            y: baseline
        )
        CTLineDraw(drawnLine, context)
    }
}
