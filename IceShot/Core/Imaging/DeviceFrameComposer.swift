import CoreGraphics
import Foundation

/// 把一张整屏截图渲染成「一台正在显示它的 MacBook」。
///
/// 纯 CoreGraphics，不依赖 SwiftUI / AppKit，与 `ScreenshotFrameComposer` 同一条理由：
/// 预览与导出共用同一个渲染器，避免「预览好看、导出不一样」。
///
/// 几何分三层：**内容 → 屏幕（黑边 + 挖孔）→ 机身（铝框）**。
/// 窗口壳只有「内容 + 一圈留白」，这里多出机身与刘海，因此不复用它的布局代码，
/// 只复用背景渐变。
nonisolated enum DeviceFrameComposer {
    /// 以「屏幕有效显示区宽 1000 px」为 1u 基准，与窗口壳同一套换算。
    private static let contentWidthForUnit: CGFloat = 1000

    /// 内容宽 → u。
    ///
    /// **不设上限**：机身比例必须与内容宽度成固定比例，否则 3024 px 的 Retina 全屏截图
    /// 会被压成「黑边和刘海都偏小」的假机器。只在极小的内容上兜底，避免边框吃掉半张图。
    private static func contentUnit(forWidth width: CGFloat) -> CGFloat {
        max(width / contentWidthForUnit, 0.8)
    }

    /// 各比例的几何值（单位 u）。集中放在一处，改视觉规格只动这里。
    ///
    /// 基准是 **14 吋 MacBook Pro（M4 / M5）** 的实物比例：
    /// 有效显示区 3024×1964 px @254 ppi ≈ 302.4×196.4 mm，
    /// 机身 312.6×221.2 mm（机身深度含铰链，屏幕面本身约 215 mm 高）。
    /// 于是 1u ≈ 0.302 mm，下面的毫米注释都由这个比例换算而来。
    ///
    /// 这些值不是「照毫米精确缩小」：真机侧面黑边只有 3.4 mm，
    /// 在 1000 px 宽的内容上如果按真实像素直译只有 11 px——这正好是这里取的 11.5u，
    /// 所以本次不再放大黑边，而是按真实比例画，靠**比例正确**而不是「加粗」来像。
    private enum Metrics {
        /// 机身外圆角。真机外沿约 13 mm，且是连续曲率（squircle），不是正圆弧。
        static let bodyCornerRadius: CGFloat = 44
        /// 连续曲率的方次。2 是正圆，越大转角越「饱满」；3 接近 Apple 硬件的观感。
        static let squircleExponent: CGFloat = 3
        /// 铝框正面宽度（机身外沿到黑色玻璃外沿）：真机约 1.7 mm。
        ///
        /// 这是「像不像」的关键：老版画到 8u（2.4 mm）还配一圈纯白高光，
        /// 结果机身读成一只白色相框，而不是一台黑色玻璃面的电脑。
        static let rim: CGFloat = 5.5
        /// 左右黑边：真机 3.4 mm。
        static let bezelSide: CGFloat = 11.5
        /// 上黑边：与左右同宽，刘海从这条边往下挖。
        static let bezelTop: CGFloat = 11.5
        /// 下黑边（下巴）：真机明显比另外三边宽，约 11.5 mm。
        ///
        /// 注意黑边与铝框是两回事：下巴 = 38u 黑边 + 5.5u 铝框 ≈ 13 mm。
        static let bezelBottom: CGFloat = 38
        /// 玻璃圆角 = 机身圆角 - 铝框宽度。
        ///
        /// 两个圆角必须**同心**，铝框在转角处才是等宽的。
        /// 老版把屏幕圆角（34u）画得比机身圆角（30u）还大，转角直接鼓出来一块。
        static var glassCornerRadius: CGFloat { bodyCornerRadius - rim }
        /// 屏幕有效显示区上圆角。真机面板只有上面两角是圆的，下面两角是直角。
        ///
        /// 这个圆角由面板切割决定，比玻璃圆角小一圈（约 6.7 mm）。
        static let panelCornerTop: CGFloat = 22
        /// 刘海：14 吋真机 185×32 pt @2x = 370×64 px ≈ 37×6.4 mm。
        static let notchWidth: CGFloat = 122
        static let notchHeight: CGFloat = 21
        /// 刘海底部两角圆角（顶部与上黑边连成一体，不需要圆角）。
        static let notchCorner: CGFloat = 7
        /// 摄像头开孔直径。太小会像噪点，这个尺寸在 100% 下刚好是一颗镜头。
        static let cameraDiameter: CGFloat = 4
    }

    /// 渲染。
    ///
    /// - Parameters:
    ///   - content: 已经渲染好标注、并且**已经按选区裁剪**的整屏内容图。
    ///   - style: 设备壳样式。
    ///   - maximumDimension: 预览用，长边不超过该值；导出时不传。
    ///   - notchHeightInUnits: 刘海高度覆盖值（u）。
    ///     调用方知道来源显示器的菜单栏高度时传进来，让刘海底边与截图里的菜单栏对齐；
    ///     `nil` 时用 14 吋真机值（21u）。外接屏的菜单栏通常比真机矮，固定 21u 会压过菜单栏底边。
    static func render(
        _ content: CGImage,
        style: DeviceFrameStyle,
        maximumDimension: Int? = nil,
        notchHeightInUnits: CGFloat? = nil
    ) throws -> CGImage {
        guard content.width > 0, content.height > 0 else {
            throw CaptureError.encodingFailed
        }

        // 以内容宽度定 1u；太小的图限制下限，避免机身占掉半张图。
        let unit = contentUnit(forWidth: CGFloat(content.width))
        let paddingBase = style.padding.baseValue * unit
        let lidBase = lidSize(
            for: CGSize(width: content.width, height: content.height)
        )
        let outputWidthBase = lidBase.width + paddingBase * 2
        let outputHeightBase = lidBase.height + paddingBase * 2

        var fit: CGFloat = 1
        if let maximumDimension, maximumDimension > 0 {
            let longest = max(outputWidthBase, outputHeightBase)
            if longest > CGFloat(maximumDimension) {
                fit = CGFloat(maximumDimension) / longest
            }
        }

        let scale = unit * fit
        let padding = paddingBase * fit
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

        // 布局全部按左上原点算；绘制时统一乘一个竖直翻转矩阵。
        let flip = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(pixelHeight)
        )
        func add(_ path: CGPath) {
            var transform = flip
            guard let flippedPath = path.copy(using: &transform) else { return }
            context.addPath(flippedPath)
        }
        func fill(_ path: CGPath, _ color: CGColor) {
            context.setFillColor(color)
            add(path)
            context.fillPath()
        }
        func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat) {
            context.setStrokeColor(color)
            context.setLineWidth(width)
            add(path)
            context.strokePath()
        }

        // 三层矩形：机身 → 玻璃（含黑边）→ 内容。
        let bodyRect = CGRect(
            x: padding,
            y: padding,
            width: lidBase.width * fit,
            height: lidBase.height * fit
        )
        let rim = Metrics.rim * scale
        let glassRect = bodyRect.insetBy(dx: rim, dy: rim)
        let bezelSide = Metrics.bezelSide * scale
        let bezelTop = Metrics.bezelTop * scale
        let bezelBottom = Metrics.bezelBottom * scale
        let contentRect = CGRect(
            x: glassRect.minX + bezelSide,
            y: glassRect.minY + bezelTop,
            width: glassRect.width - bezelSide * 2,
            height: glassRect.height - bezelTop - bezelBottom
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

        let palette = palette(for: style.finish)
        let bodyPath = squirclePath(
            bodyRect,
            cornerRadius: Metrics.bodyCornerRadius * scale,
            corners: .all,
            exponent: Metrics.squircleExponent
        )
        let glassPath = squirclePath(
            glassRect,
            cornerRadius: Metrics.glassCornerRadius * scale,
            corners: .all,
            exponent: Metrics.squircleExponent
        )

        // 2a. 落影：近距离紧、远距离散，两层叠出环境光遮蔽。
        context.saveGState()
        if style.showsShadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -16 * scale),
                blur: 38 * scale,
                color: CGColor(gray: 0, alpha: 0.36)
            )
            context.setShadow(
                offset: CGSize(width: 0, height: -28 * scale),
                blur: 82 * scale,
                color: CGColor(gray: 0, alpha: 0.16)
            )
        }
        fill(bodyPath, palette.upper)
        context.restoreGState()

        // 2b. 铝框的竖直受光：上缘亮、下缘暗。
        //     玻璃会盖住中间，实际露出来的只有 5.5u 宽的框，
        //     所以渐变要在这里就把明暗交代清楚。
        context.saveGState()
        add(bodyPath)
        context.clip()
        drawMetalGradient(
            in: context,
            rect: flipped(bodyRect, pixelHeight: pixelHeight),
            palette: palette
        )
        context.restoreGState()

        // 2c. 倒角：外沿一道暗缝 + 内侧一道高光。
        //     高光裁剪在机身内，只留内侧一半，避免在背景上糊出一圈白边。
        context.saveGState()
        add(bodyPath)
        context.clip()
        stroke(bodyPath, palette.chamfer, width: 1.8 * scale)
        context.restoreGState()
        stroke(bodyPath, palette.edge, width: max(0.8, 1.0 * scale))

        // 3. 玻璃嵌进铝框的软阴影：贴着玻璃外沿压一道模糊暗边，
        //    只留在铝框上（玻璃随后会被重新盖住），转角才不会有生硬的接缝。
        context.saveGState()
        add(bodyPath)
        context.clip()
        context.setShadow(
            offset: .zero,
            blur: 4 * scale,
            color: CGColor(gray: 0, alpha: 0.28)
        )
        stroke(glassPath, CGColor(gray: 0, alpha: 0.30), width: max(0.8, 1.2 * scale))
        context.restoreGState()

        // 3b. 玻璃底
        fill(glassPath, palette.glass)

        // 4. 内容：先裁到玻璃，再裁到「只有上圆角」的面板形状。
        //    下巴更宽，底部两角本来就落在黑边里，所以面板保持方形下角——
        //    这正是真机的特征（2021 起面板上圆下方）。
        let panelPath = squirclePath(
            contentRect,
            cornerRadius: Metrics.panelCornerTop * scale,
            corners: [.topLeft, .topRight],
            exponent: Metrics.squircleExponent
        )
        context.saveGState()
        add(glassPath)
        context.clip()
        add(panelPath)
        context.clip()
        context.draw(content, in: flipped(contentRect, pixelHeight: pixelHeight))
        context.restoreGState()

        // 5. 玻璃与铝框之间的接缝：贴着玻璃外沿压一道极细暗线，
        //    让黑色玻璃「嵌」在铝框里，而不是浮在表面。
        stroke(glassPath, palette.seam, width: max(1, 1.4 * scale))

        // 6. 刘海：从上黑边往下长，与玻璃同色。
        //    顶部落在黑边里，所以只有压住内容的底部可见；
        //    底部两角圆润，顶部不需要圆角（会和上黑边连成一片）。
        let notchWidth = Metrics.notchWidth * scale
        // 刘海高度默认取 14 吋真机值；已知菜单栏高度时按菜单栏对齐。
        // 夹在 8…30u：太小不像挖孔，太大则说明菜单栏测量异常（例如 0）。
        let resolvedNotchHeight = min(
            max(notchHeightInUnits ?? Metrics.notchHeight, 8),
            30
        )
        let notchHeight = resolvedNotchHeight * scale
        let notchRect = CGRect(
            x: glassRect.midX - notchWidth / 2,
            y: glassRect.minY,
            width: notchWidth,
            height: bezelTop + notchHeight
        )
        let notchPath = squirclePath(
            notchRect,
            cornerRadius: Metrics.notchCorner * scale,
            corners: [.bottomLeft, .bottomRight],
            exponent: Metrics.squircleExponent
        )
        fill(notchPath, palette.glass)

        // 7. 摄像头：刘海顶部的一颗小镜头。没有它，刘海就是一块黑标签。
        let cameraDiameter = Metrics.cameraDiameter * scale
        // 摄像头藏在刘海露出来的那一截里（不是上黑边里）：
        // 真机镜头约在玻璃顶边下方 5 mm，正好落在刘海露出的上三分之一。
        let cameraRect = CGRect(
            x: notchRect.midX - cameraDiameter / 2,
            y: glassRect.minY + bezelTop + notchHeight * 0.30 - cameraDiameter / 2,
            width: cameraDiameter,
            height: cameraDiameter
        )
        fill(CGPath(ellipseIn: cameraRect, transform: nil), palette.lens)
        stroke(
            CGPath(ellipseIn: cameraRect.insetBy(dx: -0.3 * scale, dy: -0.3 * scale), transform: nil),
            palette.lensRing,
            width: max(0.4, 0.5 * scale)
        )

        guard let output = context.makeImage() else {
            throw CaptureError.encodingFailed
        }
        return output
    }

    /// 机身配色。
    ///
    /// 真机是阳极氧化铝：上缘受光、下缘转暗，转角处有一道被铣出来的亮倒角。
    /// 只填纯色会让铝框和背景糊在一起，圆角也会读成「塑料切角」。
    private struct Palette {
        /// 竖直渐变的四个停靠点（从上到下）。
        let highlight: CGColor
        let upper: CGColor
        let lower: CGColor
        let shade: CGColor
        /// 外沿倒角高光。
        let chamfer: CGColor
        /// 最外沿的暗边，用来把机身从背景里切出来。
        let edge: CGColor
        /// 玻璃与铝框之间的接缝。
        let seam: CGColor
        /// 屏幕玻璃底色。真机关屏是深灰而不是纯黑，纯黑会让边界过硬。
        let glass: CGColor
        /// 摄像头开孔。
        let lens: CGColor
        let lensRing: CGColor
    }

    private static func palette(for finish: DeviceFrameStyle.Finish) -> Palette {
        switch finish {
        case .silver:
            return Palette(
                highlight: color(0xDADBDD),
                upper: color(0xD3D4D7),
                lower: color(0xC9CACE),
                shade: color(0xBEBFC3),
                chamfer: color(0xFFFFFF, alpha: 0.46),
                edge: color(0x747578, alpha: 0.90),
                seam: color(0x000000, alpha: 0.62),
                glass: color(0x08090B),
                lens: color(0x1B1D22),
                lensRing: color(0x3C4048, alpha: 0.85)
            )
        case .spaceGray:
            return Palette(
                highlight: color(0x6B6C72),
                upper: color(0x5C5D63),
                lower: color(0x4D4E54),
                shade: color(0x3C3D43),
                chamfer: color(0xD9DBDF, alpha: 0.26),
                edge: color(0x111214, alpha: 0.95),
                seam: color(0x000000, alpha: 0.72),
                glass: color(0x050506),
                lens: color(0x14161A),
                lensRing: color(0x2E3138, alpha: 0.9)
            )
        }
    }

    /// 四点竖直渐变，做出阳极氧化铝的柔和受光。
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

    /// 连续圆角（squircle）矩形路径。
    ///
    /// 用超椭圆 `|x|^n + |y|^n = 1` 采样，而不是圆弧：
    /// Apple 硬件的转角曲率是连续过渡的，正圆弧会在直线与转角交接处留下
    /// 一道肉眼可见的「折点」，在大圆角、宽机身上尤其像塑料。
    ///
    /// - Parameters:
    ///   - corners: 需要倒圆的角。刘海只圆下面两角、面板只圆上面两角。
    ///   - exponent: 2 为正圆，越大越饱满。3 接近真机。
    private static func squirclePath(
        _ rect: CGRect,
        cornerRadius radius: CGFloat,
        corners: Corners,
        exponent: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let r = min(radius, min(rect.width, rect.height) / 2)
        guard r > 0, corners != [] else {
            path.addRect(rect)
            return path
        }

        // 每角采样段数。24 段在 2u 缩放、2000 px 宽的输出上弦高不足 0.1 px。
        let segments = 24
        let power = 2 / max(exponent, 2)

        // 在**屏幕坐标**（左上原点）里构造，调用方负责翻转。
        //
        // 每个角用一个局部超椭圆：O 是转角圆心，inX / inY 是从圆心指向矩形内部的方向。
        // 超椭圆在 45° 处比正圆更贴近角点，也就是「更饱满」——
        // 这就是 Apple 连续圆角的观感来源。
        //
        // 走向为顺时针：左上 → 右上 → 右下 → 左下。
        // 右上、左下两个角的参数方向相反，否则曲线会绕到矩形外面。
        func cornerPoints(
            center: CGPoint,
            inX: CGFloat,
            inY: CGFloat,
            reversed: Bool
        ) -> [CGPoint] {
            (0...segments).map { index in
                let step = reversed ? segments - index : index
                let angle = CGFloat(step) / CGFloat(segments) * .pi / 2
                let u = r * pow(cos(angle), power)
                let v = r * pow(sin(angle), power)
                return CGPoint(x: center.x - inX * u, y: center.y - inY * v)
            }
        }

        func addLine(_ point: CGPoint) {
            path.addLine(to: point)
        }

        // 从左上角之后的上边开始，顺时针走一圈。
        path.move(to: CGPoint(
            x: rect.minX + (corners.contains(.topLeft) ? r : 0),
            y: rect.minY
        ))

        if corners.contains(.topRight) {
            addLine(CGPoint(x: rect.maxX - r, y: rect.minY))
            for point in cornerPoints(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                inX: -1,
                inY: 1,
                reversed: true
            ) {
                addLine(point)
            }
        } else {
            addLine(CGPoint(x: rect.maxX, y: rect.minY))
        }

        if corners.contains(.bottomRight) {
            addLine(CGPoint(x: rect.maxX, y: rect.maxY - r))
            for point in cornerPoints(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                inX: -1,
                inY: -1,
                reversed: false
            ) {
                addLine(point)
            }
        } else {
            addLine(CGPoint(x: rect.maxX, y: rect.maxY))
        }

        if corners.contains(.bottomLeft) {
            addLine(CGPoint(x: rect.minX + r, y: rect.maxY))
            for point in cornerPoints(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                inX: 1,
                inY: -1,
                reversed: true
            ) {
                addLine(point)
            }
        } else {
            addLine(CGPoint(x: rect.minX, y: rect.maxY))
        }

        if corners.contains(.topLeft) {
            addLine(CGPoint(x: rect.minX, y: rect.minY + r))
            for point in cornerPoints(
                center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                inX: 1,
                inY: 1,
                reversed: false
            ) {
                addLine(point)
            }
        } else {
            addLine(CGPoint(x: rect.minX, y: rect.minY))
        }

        path.closeSubpath()
        return path
    }

    /// 需要倒圆的角（按屏幕坐标，左上原点）。
    private struct Corners: OptionSet {
        let rawValue: Int
        static let topLeft = Corners(rawValue: 1 << 0)
        static let topRight = Corners(rawValue: 1 << 1)
        static let bottomRight = Corners(rawValue: 1 << 2)
        static let bottomLeft = Corners(rawValue: 1 << 3)
        static let all: Corners = [.topLeft, .topRight, .bottomRight, .bottomLeft]
    }

    private static func flipped(_ rect: CGRect, pixelHeight: Int) -> CGRect {
        CGRect(
            x: rect.minX,
            y: CGFloat(pixelHeight) - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 机身（屏幕面）尺寸，不含外边距。
    ///
    /// 单测用它锁死「14 吋真机比例」，`outputSize` 也走这里，避免两处各算一遍。
    static func lidSize(for contentPixelSize: CGSize) -> CGSize {
        let unit = contentUnit(forWidth: contentPixelSize.width)
        let width = contentPixelSize.width
            + (Metrics.bezelSide + Metrics.rim) * 2 * unit
        let height = contentPixelSize.height
            + (Metrics.bezelTop + Metrics.bezelBottom + Metrics.rim * 2) * unit
        return CGSize(width: width, height: height)
    }

    /// 输出尺寸（导出用）。单测与预览 sizing 共用。
    static func outputSize(
        for contentPixelSize: CGSize,
        style: DeviceFrameStyle
    ) -> CGSize {
        let unit = contentUnit(forWidth: contentPixelSize.width)
        let padding = style.padding.baseValue * unit
        let lid = lidSize(for: contentPixelSize)
        return CGSize(
            width: lid.width + padding * 2,
            height: lid.height + padding * 2
        )
    }
}
