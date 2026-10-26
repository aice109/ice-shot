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

    /// 各比例的几何值（单位 u）。
    ///
    /// **全部取自 Apple 官网产品图实测**（IceShot 截图 2454×1508，
    /// 以屏幕宽 1000u 归一）。先前那套「窗口式内嵌屏幕」的几何是错的：
    /// 真机产品照是「上盖立起 + 底座平放」两层，屏幕几乎占满上盖，
    /// 屏幕下方是约 10u 的上盖下缘，再往下才是独立的底座。
    private enum Metrics {
        /// 上盖圆角。官图里上盖四角都是圆角矩形，半径不大。
        static let lidCornerRadius: CGFloat = 18
        /// 屏幕圆角。官图里屏幕是圆角矩形（不是「上圆下方」）。
        static let screenCornerRadius: CGFloat = 14
        /// 侧黑边。官图实测只有约 1px（屏幕宽 1807px），即 0.6u —— 现在就是全面屏。
        static let bezel: CGFloat = 2
        /// 上盖下缘：屏幕底边到上盖底边。
        static let lidBottomInset: CGFloat = 10
        /// 刘海宽 / 高。官图实测 214×38px，占屏宽 11.84%。
        ///
        /// 形状是**近乎直角的小圆角矩形**（逐行扫描：y=178 宽 218 → y=212 宽 202，
        /// 角半径仅约 4.5u），不是圆润的「耳朵」。
        static let notchWidth: CGFloat = 118
        static let notchHeight: CGFloat = 21
        static let notchCornerRadius: CGFloat = 5
        /// 底座：比上盖宽得多（实测宽比 1.213）。
        static let baseWidthRatio: CGFloat = 1.213
        static let baseHeight: CGFloat = 42
        /// 上盖与底座之间的间隙。
        static let baseGap: CGFloat = 41
        /// 底座圆角（左右两端是半圆收尾）。
        static var baseCornerRadius: CGFloat { baseHeight / 2 }
    }

    /// 渲染。
    ///
    /// 布局自上而下三层（与原厂产品照一致）：
    /// 1. **上盖**：屏幕（几乎占满）+ 底部约 10u 的下缘；
    /// 2. **间隙**：上盖与底座之间的空隙；
    /// 3. **底座**：比上盖宽 21% 的键盘面，左右两端半圆收尾。
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

        let unit = min(max(CGFloat(content.width) / contentWidthForUnit, 0.8), 2.0)
        let paddingBase = style.padding.baseValue * unit

        // —— 上盖 ——
        let lidWidthBase = CGFloat(content.width) + Metrics.bezel * unit * 2
        let lidHeightBase = CGFloat(content.height) + Metrics.lidBottomInset * unit
        // —— 底座 ——
        let baseWidthBase = lidWidthBase * Metrics.baseWidthRatio
        let baseHeightBase = Metrics.baseHeight * unit
        let gapBase = Metrics.baseGap * unit

        // 整张画的宽度由底座决定（它最宽）。
        let outputWidthBase = baseWidthBase + paddingBase * 2
        let outputHeightBase = lidHeightBase + gapBase + baseHeightBase + paddingBase * 2

        var fit: CGFloat = 1
        if let maximumDimension, maximumDimension > 0 {
            let longest = max(outputWidthBase, outputHeightBase)
            if longest > CGFloat(maximumDimension) {
                fit = CGFloat(maximumDimension) / longest
            }
        }

        let scale = unit * fit
        let padding = paddingBase * fit
        let lidWidth = lidWidthBase * fit
        let lidHeight = lidHeightBase * fit
        let baseWidth = baseWidthBase * fit
        let baseHeight = baseHeightBase * fit
        let gap = gapBase * fit

        let outputWidth = max(1, Int((outputWidthBase * fit).rounded()))
        let outputHeight = max(1, Int((outputHeightBase * fit).rounded()))

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
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

        // 布局按左上原点算，绘制时翻成 CGContext 的左下原点。
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX,
                y: CGFloat(outputHeight) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }

        // 上盖与底座水平居中。
        let lidRect = CGRect(
            x: padding + (baseWidth - lidWidth) / 2,
            y: padding,
            width: lidWidth,
            height: lidHeight
        )
        let baseRect = CGRect(
            x: padding,
            y: lidRect.maxY + gap,
            width: baseWidth,
            height: baseHeight
        )
        let palette = palette(for: style.finish)

        // 1. 背景
        if let gradient = ScreenshotFramePalette.gradient(for: style.background.shared) {
            ScreenshotFrameComposer.drawLinearGradient(
                from: CGPoint(x: 0, y: CGFloat(outputHeight)),
                to: CGPoint(x: CGFloat(outputWidth), y: 0),
                colors: [gradient.start, gradient.end],
                in: context
            )
        }

        // 2. 底座落影 + 底座本体
        let basePath = CGPath(
            roundedRect: flipped(baseRect),
            cornerWidth: Metrics.baseCornerRadius * scale,
            cornerHeight: Metrics.baseCornerRadius * scale,
            transform: nil
        )
        drawWithShadow(
            in: context,
            path: basePath,
            fill: palette.baseTop,
            showsShadow: style.showsShadow,
            scale: scale
        )
        // 底座的竖直渐变：上表面亮、靠下转暗，做出厚度感。
        context.saveGState()
        context.addPath(basePath)
        context.clip()
        // 底座不是均匀的一根：上表面受光最亮，往下是前缘与侧壁转暗，
        // 官图实测亮度 97 → 14。四段渐变才做出「厚度」。
        drawGradient(
            in: context,
            rect: flipped(baseRect),
            colors: [
                palette.baseTop,
                palette.baseMid,
                palette.baseBottom,
                palette.baseEdge,
            ],
            locations: [0, 0.22, 0.62, 1]
        )
        context.restoreGState()

        // 3. 上盖落影 + 上盖本体
        let lidPath = CGPath(
            roundedRect: flipped(lidRect),
            cornerWidth: Metrics.lidCornerRadius * scale,
            cornerHeight: Metrics.lidCornerRadius * scale,
            transform: nil
        )
        drawWithShadow(
            in: context,
            path: lidPath,
            fill: palette.lidTop,
            showsShadow: style.showsShadow,
            scale: scale
        )
        context.saveGState()
        context.addPath(lidPath)
        context.clip()
        drawGradient(
            in: context,
            rect: flipped(lidRect),
            colors: [palette.lidTop, palette.lidBottom],
            locations: [0, 1]
        )
        context.restoreGState()

        // 4. 屏幕：占上盖宽度，贴顶上沿，下方留 lidBottomInset 作为上盖下缘。
        let bezel = Metrics.bezel * scale
        let screenRect = CGRect(
            x: lidRect.minX + bezel,
            y: lidRect.minY,
            width: lidRect.width - bezel * 2,
            height: lidRect.height - Metrics.lidBottomInset * scale
        )
        let screenPath = CGPath(
            roundedRect: flipped(screenRect),
            cornerWidth: Metrics.screenCornerRadius * scale,
            cornerHeight: Metrics.screenCornerRadius * scale,
            transform: nil
        )
        context.saveGState()
        context.addPath(screenPath)
        context.clip()
        context.draw(content, in: flipped(screenRect))

        // 5. 刘海：压在屏幕顶部正中。
        //    官图实测是近乎直角的圆角矩形（角半径约 5u），不是圆润的耳朵。
        let notchWidth = Metrics.notchWidth * scale
        let notchHeight = Metrics.notchHeight * scale
        let notchRect = CGRect(
            x: screenRect.midX - notchWidth / 2,
            y: screenRect.minY,
            width: notchWidth,
            height: notchHeight
        )
        let notchRadius = Metrics.notchCornerRadius * scale
        let notchPath = CGMutablePath()
        // 只有两个下角是圆的，上沿贴着屏幕顶边。
        let fr = flipped(notchRect)
        notchPath.move(to: CGPoint(x: fr.minX, y: fr.maxY))
        notchPath.addLine(to: CGPoint(x: fr.minX, y: fr.minY + notchRadius))
        notchPath.addQuadCurve(
            to: CGPoint(x: fr.minX + notchRadius, y: fr.minY),
            control: CGPoint(x: fr.minX, y: fr.minY)
        )
        notchPath.addLine(to: CGPoint(x: fr.maxX - notchRadius, y: fr.minY))
        notchPath.addQuadCurve(
            to: CGPoint(x: fr.maxX, y: fr.minY + notchRadius),
            control: CGPoint(x: fr.maxX, y: fr.minY)
        )
        notchPath.addLine(to: CGPoint(x: fr.maxX, y: fr.maxY))
        notchPath.closeSubpath()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(notchPath)
        context.fillPath()
        context.restoreGState()

        // 6. 上盖外沿高光（金属倒角）
        context.saveGState()
        context.addPath(lidPath)
        context.setStrokeColor(palette.rimHighlight)
        context.setLineWidth(max(1, 1.2 * scale))
        context.strokePath()
        context.restoreGState()

        guard let output = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return output
    }

    /// 填充路径并附带投影。投影分近、远两层，模拟环境光遮蔽。
    private static func drawWithShadow(
        in context: CGContext,
        path: CGPath,
        fill: CGColor,
        showsShadow: Bool,
        scale: CGFloat
    ) {
        context.saveGState()
        if showsShadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -8 * scale),
                blur: 22 * scale,
                color: CGColor(gray: 0, alpha: 0.34)
            )
            context.setShadow(
                offset: CGSize(width: 0, height: -14 * scale),
                blur: 44 * scale,
                color: CGColor(gray: 0, alpha: 0.16)
            )
        }
        context.setFillColor(fill)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// 任意停靠点的竖直渐变。
    private static func drawGradient(
        in context: CGContext,
        rect: CGRect,
        colors: [CGColor],
        locations: [CGFloat]
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
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

    /// 机身配色。上盖与底座分开给，官图里两者受光不同。
    private struct Palette {
        let lidTop: CGColor
        let lidBottom: CGColor
        /// 底座上表面（受光面）。
        let baseTop: CGColor
        /// 底座侧壁。
        let baseMid: CGColor
        /// 底座下沿。
        let baseBottom: CGColor
        /// 底座最暗的一道收边。
        let baseEdge: CGColor
        let rimHighlight: CGColor
    }

    private static func palette(for finish: DeviceFrameStyle.Finish) -> Palette {
        switch finish {
        case .silver:
            return Palette(
                lidTop: color(0xE8E9EB),
                lidBottom: color(0xC9CACE),
                baseTop: color(0xF2F3F4),
                baseMid: color(0xC8C9CC),
                baseBottom: color(0x8E8F93),
                baseEdge: color(0x6E6F73),
                rimHighlight: color(0xFFFFFF, alpha: 0.55)
            )
        case .spaceGray:
            return Palette(
                lidTop: color(0x4E4E54),
                lidBottom: color(0x333338),
                baseTop: color(0x6C6C72),
                baseMid: color(0x46464C),
                baseBottom: color(0x2E2E33),
                baseEdge: color(0x1E1E22),
                rimHighlight: color(0x9A9AA0, alpha: 0.45)
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
        let padding = style.padding.baseValue * unit
        let lidWidth = contentPixelSize.width + Metrics.bezel * unit * 2
        let lidHeight = contentPixelSize.height + Metrics.lidBottomInset * unit
        let baseWidth = lidWidth * Metrics.baseWidthRatio
        let baseHeight = Metrics.baseHeight * unit
        let gap = Metrics.baseGap * unit
        return CGSize(
            width: baseWidth + padding * 2,
            height: lidHeight + gap + baseHeight + padding * 2
        )
    }
}
