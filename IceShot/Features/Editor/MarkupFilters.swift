import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// 涂抹式马赛克 / 模糊的局部滤镜缓存。
///
/// 渲染管线（坐标一律是原图像素、左上原点）：
/// 1. 取笔迹包围盒 + 笔刷半径 + 滤镜半径作为处理区域，从原图裁出来；
/// 2. 在裁剪区做 `CIPixellate` / `CIGaussianBlur`；
/// 3. 把笔迹描边（圆头圆角）栅格化成遮罩；
/// 4. `CIBlendWithMask` 把滤镜结果按遮罩贴回原图，输出一张不透明的小图，
///    直接画到 Canvas 对应矩形上。
///
/// `preview: true` 是拖拽中的实时预览：长边降采样到 `previewDimension` 以内再放大绘制，
/// 保证大区域涂抹也不掉帧；提交后按原图像素重新生成一次。
///
/// 马赛克块栅格锚定在原图像素 0 点（见 `pixelateCenter`），因此同一张图上不同笔画的
/// 块边界完全一致，涂抹过程中图案也不会「游动」。
@MainActor
final class MarkupFilterCache {
    struct Key: Hashable {
        let id: UUID
        let kind: AnnotationKind
        let rect: CGRect
        let amount: CGFloat
        let redactionStyle: RedactionStyle
        let brushWidth: CGFloat
        let color: EditorColor
        /// 采样点哈希：涂抹过程中点集每帧都在变。
        let pointsHash: Int
        let preview: Bool
    }

    struct Result {
        let image: CGImage
        /// 绘制目标矩形（原图像素坐标）；预览图比它小，由绘制方放大。
        let rect: CGRect
        let isPreview: Bool
    }

    /// 预览降采样的长边上限。
    static let previewDimension: CGFloat = 720

    private let context = CIContext()
    private var storage: [Key: CGImage] = [:]
    /// 预览与正式结果分开淘汰：拖动中的预览帧不能把已提交标注的正式结果挤出去。
    private var previewOrder: [Key] = []
    private var finalOrder: [Key] = []
    private let previewLimit = 6
    private let finalLimit = 8

    /// 返回可绘制的滤镜图（原图像素坐标）。非马赛克 / 模糊标注返回 `nil`。
    func result(
        for annotation: EditorAnnotation,
        source: CGImage,
        preview: Bool = false
    ) -> Result? {
        guard annotation.kind.needsSourceImage else { return nil }
        guard annotation.points.count > 1 else { return nil }

        let sourceBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(source.width),
            height: CGFloat(source.height)
        )
        // 处理区域要比笔迹大：笔刷描边有一半在路径外侧，模糊还要采样邻域。
        let padding = annotation.brushWidth / 2 + annotation.filterAmount + 2
        let clipped = annotation.bounds
            .insetBy(dx: -padding, dy: -padding)
            .intersection(sourceBounds)
            .integral
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }

        let key = Key(
            id: annotation.id,
            kind: annotation.kind,
            rect: clipped,
            amount: annotation.filterAmount,
            redactionStyle: annotation.redactionStyle,
            brushWidth: annotation.brushWidth,
            color: annotation.style.color,
            pointsHash: hash(points: annotation.points),
            preview: preview
        )
        if let cached = storage[key] {
            return Result(image: cached, rect: clipped, isPreview: preview)
        }
        guard let filtered = makeImage(
            kind: annotation.kind,
            amount: annotation.filterAmount,
            redactionStyle: annotation.redactionStyle,
            brushWidth: annotation.brushWidth,
            color: annotation.style.color,
            points: annotation.points,
            rect: clipped,
            source: source,
            preview: preview
        ) else {
            return nil
        }
        store(filtered, for: key)
        return Result(image: filtered, rect: clipped, isPreview: preview)
    }

    private func makeImage(
        kind: AnnotationKind,
        amount: CGFloat,
        redactionStyle: RedactionStyle,
        brushWidth: CGFloat,
        color: EditorColor,
        points: [CGPoint],
        rect: CGRect,
        source: CGImage,
        preview: Bool
    ) -> CGImage? {
        guard let cropped = try? ImageCropper.crop(source, to: rect) else { return nil }

        // 预览降采样：块大小 / 半径 / 笔宽 / 路径坐标按同一比例缩放，放大绘制后视觉强度不变。
        let factor = preview
            ? max(1, max(rect.width, rect.height) / Self.previewDimension)
            : 1
        // 原图像素 → 处理图像素。遮罩与网格都画在降采样后的位图上，
        // 路径坐标必须跟着 `scale` 换算，否则预览会按原图坐标画在缩小位图上（涂抹漂移、区域放大）。
        let scale = 1 / factor
        // 处理图上的马赛克块大小；正式渲染与预览都先用它对齐块栅格。
        let block = max(2, amount / factor)

        var input = CIImage(cgImage: cropped)
        if factor > 1 {
            input = input.transformed(
                by: CGAffineTransform(scaleX: 1 / factor, y: 1 / factor)
            )
        }
        let extent = input.extent
        let outputExtent = CGRect(
            x: 0,
            y: 0,
            width: max(1, extent.width.rounded()),
            height: max(1, extent.height.rounded())
        )
        // 边缘像素向外延展，避免滤镜在区域边界取到透明像素。
        let clamped = input.clampedToExtent()

        guard kind.needsSourceImage else { return nil }

        let filtered: CIImage
        switch redactionStyle {
        case .mosaic:
            filtered = Self.mosaicImage(
                input: clamped,
                block: block,
                center: Self.pixelateCenter(rect: rect, block: block, scale: scale)
            ) ?? input
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = clamped
            filter.radius = Float(max(0.5, amount / factor))
            filtered = filter.outputImage ?? input
        case .noise:
            filtered = noiseImage(
                rect: rect,
                cell: max(1, amount / factor),
                extent: outputExtent,
                scale: scale
            ) ?? input
        case .solid:
            let solidColor = CIColor(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            )
            filtered = CIImage(color: solidColor).cropped(to: outputExtent)
        }

        guard let mask = makeMask(
            points: points,
            rect: rect,
            size: outputExtent.size,
            brushWidth: brushWidth,
            scale: scale
        ) else {
            return nil
        }

        // 背景用透明色：输出只保留笔迹内的像素，画到 Canvas 上不会盖掉
        // 原图与前一条笔迹（重叠涂抹可以叠加）。
        let blend = CIFilter.blendWithMask()
        blend.inputImage = filtered.cropped(to: outputExtent)
        blend.backgroundImage = CIImage(color: .clear).cropped(to: outputExtent)
        blend.maskImage = mask.cropped(to: outputExtent)
        guard let output = blend.outputImage else { return nil }
        // 固定成 RGBA8，保证遮罩外的透明度在 Canvas 合成时生效。
        guard let blended = context.createCGImage(
            output,
            from: outputExtent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            return nil
        }

        // 马赛克加一层细网格：纯白 / 纯色区域也能一眼看出已被打码。
        guard redactionStyle == .mosaic else { return blended }
        return addMosaicGrid(
            to: blended,
            rect: rect,
            block: block,
            points: points,
            brushWidth: brushWidth,
            scale: scale
        )
    }

    /// 稳定相位的雪花噪点（固定种子生成一次，再平铺到裁剪区）。
    private func noiseImage(
        rect: CGRect,
        cell: CGFloat,
        extent: CGRect,
        scale: CGFloat
    ) -> CIImage? {
        guard let tile = noiseTile else { return nil }
        let tileExtent = tile.extent
        let period = CGSize(
            width: tileExtent.width * cell,
            height: tileExtent.height * cell
        )
        // 相位锚在原图像素 0 点：预览降采样后也要算出同一相位，放大后噪点才不会「游动」。
        let translation = CGPoint(
            x: (-rect.minX * scale).truncatingRemainder(dividingBy: period.width),
            y: (rect.maxY * scale).truncatingRemainder(dividingBy: period.height)
        )
        let transform = CGAffineTransform(scaleX: cell, y: cell)
            .concatenating(CGAffineTransform(translationX: translation.x, y: translation.y))
        let filter = CIFilter.affineTile()
        filter.inputImage = tile
        filter.transform = transform
        return filter.outputImage?.cropped(to: extent)
    }

    /// 在马赛克上叠一层对齐块栅格的细线。
    ///
    /// 用「中灰 + `difference` + 半透明」：白底变暗、黑底变亮、中灰底也明显，
    /// 任何底色都能看出块结构。绘制前按笔迹路径裁剪，线条只落在涂抹区域内。
    private func addMosaicGrid(
        to image: CGImage,
        rect: CGRect,
        block: CGFloat,
        points: [CGPoint],
        brushWidth: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, points.count > 1 else { return image }
        guard let gridContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        gridContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 笔迹路径（y-up，和滤镜图同坐标系），用于把网格限制在涂抹区域内。
        let strokePath = CGMutablePath()
        for (index, point) in points.enumerated() {
            let local = Self.localPoint(point, rect: rect, scale: scale)
            if index == 0 {
                strokePath.move(to: local)
            } else {
                strokePath.addLine(to: local)
            }
        }
        let clipPath = strokePath.copy(
            strokingWithWidth: max(1, brushWidth * scale),
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )

        gridContext.saveGState()
        gridContext.addPath(clipPath)
        gridContext.clip()
        gridContext.setBlendMode(.difference)
        gridContext.setStrokeColor(CGColor(gray: 0.5, alpha: 0.5))
        // 线宽按同一个比例缩放：放大绘制后仍是约 1 原图像素的细线。
        gridContext.setLineWidth(max(0.25, scale))
        gridContext.beginPath()

        let startX = (block - (rect.minX * scale).truncatingRemainder(dividingBy: block))
            .truncatingRemainder(dividingBy: block)
        var x = startX + 0.5
        while x < CGFloat(width) {
            gridContext.move(to: CGPoint(x: x, y: 0))
            gridContext.addLine(to: CGPoint(x: x, y: CGFloat(height)))
            x += block
        }

        let startY = (rect.maxY * scale).truncatingRemainder(dividingBy: block)
        var y = startY + 0.5
        while y < CGFloat(height) {
            gridContext.move(to: CGPoint(x: 0, y: y))
            gridContext.addLine(to: CGPoint(x: CGFloat(width), y: y))
            y += block
        }

        gridContext.strokePath()
        gridContext.restoreGState()
        return gridContext.makeImage() ?? image
    }

    /// 固定种子的 32×32 灰度噪点瓦片；只生成一次，避免拖动时噪点闪烁。
    private lazy var noiseTile: CIImage? = {
        let size = 32
        guard let tileContext = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let buffer = tileContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<(size * size) {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let value = UInt8(truncatingIfNeeded: seed >> 24)
            buffer[index * 4] = value
            buffer[index * 4 + 1] = value
            buffer[index * 4 + 2] = value
            buffer[index * 4 + 3] = 255
        }

        guard let cgImage = tileContext.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }()

    /// 笔迹描边栅格化成遮罩：白色 = 应用滤镜，黑色 = 保留原图。
    ///
    /// Core Image 的坐标是左下原点，这里把「左上原点」的路径点翻转成 y-up，
    /// 再按 `scale` 换算到处理图（预览时是降采样位图）像素。
    private func makeMask(
        points: [CGPoint],
        rect: CGRect,
        size: CGSize,
        brushWidth: CGFloat,
        scale: CGFloat
    ) -> CIImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(max(1, brushWidth * scale))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        for (index, point) in points.enumerated() {
            let local = Self.localPoint(point, rect: rect, scale: scale)
            if index == 0 {
                context.move(to: local)
            } else {
                context.addLine(to: local)
            }
        }
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    /// 方块马赛克：`CIPixellate`，`block` 已换算到当前处理图分辨率。
    private nonisolated static func mosaicImage(
        input: CIImage,
        block: CGFloat,
        center: CGPoint
    ) -> CIImage? {
        let filter = CIFilter.pixellate()
        filter.inputImage = input
        filter.scale = Float(max(2, block))
        filter.center = center
        return filter.outputImage
    }

    /// 让马赛克块边界落在原图像素 `amount` 的整数倍上。
    ///
    /// `CIPixellate` 的块边界是 `center + k × scale`：把裁剪区原点换算回处理图坐标
    /// 取余，就能让整张图的块栅格共用同一相位（不同笔画、拖动过程中都不会跳动）。
    private nonisolated static func pixelateCenter(
        rect: CGRect,
        block: CGFloat,
        scale: CGFloat
    ) -> CGPoint {
        let effective = max(2, block)
        let remainderX = (rect.minX * scale).truncatingRemainder(dividingBy: effective)
        let remainderY = (rect.maxY * scale).truncatingRemainder(dividingBy: effective)
        return CGPoint(x: -remainderX, y: remainderY)
    }

    /// 原图坐标（左上原点）→ 处理图坐标（左下原点），并按 `scale` 缩放到处理图像素。
    ///
    /// 预览降采样时处理图比裁剪区小，路径坐标和笔宽都要同步乘 `scale`；
    /// 正式渲染 `scale == 1`，与直接按原图像素绘制等价。
    private nonisolated static func localPoint(
        _ point: CGPoint,
        rect: CGRect,
        scale: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: (point.x - rect.minX) * scale,
            y: (rect.maxY - point.y) * scale
        )
    }

    private func hash(points: [CGPoint]) -> Int {
        var hasher = Hasher()
        hasher.combine(points.count)
        for point in points {
            hasher.combine(point.x.rounded())
            hasher.combine(point.y.rounded())
        }
        return hasher.finalize()
    }

    private func store(_ image: CGImage, for key: Key) {
        storage[key] = image
        if key.preview {
            previewOrder.removeAll { $0 == key }
            previewOrder.append(key)
            while previewOrder.count > previewLimit {
                storage.removeValue(forKey: previewOrder.removeFirst())
            }
        } else {
            finalOrder.removeAll { $0 == key }
            finalOrder.append(key)
            while finalOrder.count > finalLimit {
                storage.removeValue(forKey: finalOrder.removeFirst())
            }
        }
    }
}
