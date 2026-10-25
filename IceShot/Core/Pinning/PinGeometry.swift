import CoreGraphics

/// 贴图窗口的尺寸与位置计算（纯几何，便于单测）。
///
/// 约定：`topLeft` 与 `origin` 都在 AppKit 屏幕坐标（左下原点）里表达，
/// 但调用方传入的是「贴图显示的左上角点」，更贴近截图选区的直觉。
enum PinGeometry {
    /// 缩到最小也不能小于这个尺寸（pt），否则抓不住也看不清。
    static let minimumSize: CGFloat = 40

    /// 关闭按钮的圆形直径（pt）。与系统红绿灯的视觉重量对齐。
    static let closeButtonDiameter: CGFloat = 18
    /// 关闭按钮距贴图右上角的内缩（pt）。
    static let closeButtonInset: CGFloat = 8

    /// 关闭按钮在贴图视图坐标（左上原点）中的中心点。
    ///
    /// 放在**右上角**：贴图常常是以截图原位贴出的，右下角往往正是用户要继续看的内容；
    /// 右上角在多数界面里是「关闭」的习惯位置。
    static func closeButtonCenter(in size: CGSize) -> CGPoint {
        let offset = closeButtonInset + closeButtonDiameter / 2
        return CGPoint(x: max(offset, size.width - offset), y: offset)
    }

    /// 指针是否落在关闭按钮上（含一点容差，便于点按）。
    static func isOverCloseButton(point: CGPoint, size: CGSize, tolerance: CGFloat = 2) -> Bool {
        let center = closeButtonCenter(in: size)
        let radius = closeButtonDiameter / 2 + tolerance
        let dx = point.x - center.x
        let dy = point.y - center.y
        return dx * dx + dy * dy <= radius * radius
    }
    /// 贴图初始不得超出所在屏幕可用区域的比例。
    static let maximumScreenRatio: CGFloat = 0.85

    /// 初始显示尺寸：按屏幕缩放把像素换算成 pt，超屏时等比缩小。
    static func initialSize(
        imageSize: CGSize,
        scale: CGFloat,
        screenFrame: CGRect
    ) -> CGSize {
        let pointScale = max(scale, 1)
        let width = max(1, imageSize.width) / pointScale
        let height = max(1, imageSize.height) / pointScale

        let maxWidth = max(minimumSize, screenFrame.width * maximumScreenRatio)
        let maxHeight = max(minimumSize, screenFrame.height * maximumScreenRatio)
        let factor = min(1, min(maxWidth / width, maxHeight / height))

        return CGSize(
            width: max(minimumSize, width * factor),
            height: max(minimumSize, height * factor)
        )
    }

    /// 窗口原点（AppKit 左下原点）。
    /// - `topLeft` 非空时按「贴图左上角对齐这个点」摆放（截图选区原位贴图）；
    /// - 为空时居中在 `visibleFrame`。
    /// 结果总会被夹进可见区域，避免贴图跑到屏幕外拿不回来。
    static func origin(
        topLeft: CGPoint?,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let anchor = topLeft ?? CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY + size.height / 2
        )
        let x = clamp(
            anchor.x,
            lower: visibleFrame.minX,
            upper: max(visibleFrame.minX, visibleFrame.maxX - size.width)
        )
        let y = clamp(
            anchor.y - size.height,
            lower: visibleFrame.minY,
            upper: max(visibleFrame.minY, visibleFrame.maxY - size.height)
        )
        return CGPoint(x: x, y: y)
    }

    /// 缩放的拖动边 / 角。
    enum ResizeEdge: Equatable {
        case top, bottom, leading, trailing
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var touchesLeft: Bool { self == .leading || self == .topLeading || self == .bottomLeading }
        var touchesRight: Bool { self == .trailing || self == .topTrailing || self == .bottomTrailing }
        var touchesTop: Bool { self == .top || self == .topLeading || self == .topTrailing }
        var touchesBottom: Bool { self == .bottom || self == .bottomLeading || self == .bottomTrailing }

        /// 光标提示用的统一方向（`PointerCursor` 只认 `ResizeAxis`）。
        var axis: ResizeAxis {
            switch self {
            case .top: return .top
            case .bottom: return .bottom
            case .leading: return .leading
            case .trailing: return .trailing
            case .topLeading: return .topLeading
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
    }

    /// 按比例换算缩放后的窗口 frame，**直接按目标高度算**，不经过任何「基准 frame + 位移」的中间量。
    ///
    /// 为什么不用「基准 frame + 位移」那套：它要求调用方每次都把指针位置换算成
    /// 「相对按下点的位移」，指针一旦离开贴图（缩放时几乎必然发生），
    /// `locationInWindow` 就落在窗口外，位移与基准 frame 的配对关系随之漂移——
    /// 表现就是拖快点时尺寸跟不上指针、画面一帧一帧追。
    /// 这里只认「目标高度 + 哪个锚点固定」，每一步都是绝对量，没有累计误差。
    ///
    /// - Parameters:
    ///   - baseFrame: 缩放开始时的窗口 frame，只用来取要固定的那条边。
    ///   - height: 目标高度（pt），调用方已按指针位置算好，内部再夹一次最小值。
    ///   - imageAspect: 图片宽 / 高。
    /// - Returns: 保持图片比例的窗口 frame（AppKit 坐标）。
    static func frameSizedToHeight(
        baseFrame: CGRect,
        height requestedHeight: CGFloat,
        imageAspect: CGFloat,
        anchor: ResizeEdge
    ) -> CGRect {
        guard imageAspect > 0, baseFrame.width > 0, baseFrame.height > 0 else {
            return baseFrame
        }
        let height = max(minimumSize, requestedHeight)
        let width = max(minimumSize, height * imageAspect)
        let originX = anchor.touchesLeft ? baseFrame.maxX - width : baseFrame.minX
        let originY = anchor.touchesTop ? baseFrame.minY : baseFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// 按指针的**屏幕绝对坐标**算出目标高度，让被拖的那个角跟着指针走。
    ///
    /// 为什么必须用屏幕坐标：缩放期间窗口的尺寸和原点都在变，`locationInWindow`
    /// 的参照系每帧不同。拿它当绝对位置，等于用一把正在移动的尺子量长度，
    /// 误差会随缩放幅度累积——表现就是「缩得越厉害，角离指针越远」。
    /// `NSEvent.mouseLocation` 不随窗口变化，是唯一正确的参照。
    ///
    /// 算法：以**按下瞬间的指针位置**为原点，把指针位移投影到对角线方向 (aspect, 1) 上。
    /// 这样：
    /// - 按下不拖时位移为零，高度逐位等于原高（不会一按就跳）；
    /// - 指针沿对角线拖动时，角精确落在指针上；
    /// - 指针只往一个方向拖时，只取沿对角线那个分量，不会被垂直偏差撑大。
    ///
    /// - Parameters:
    ///   - pointer: 指针的屏幕坐标（AppKit，左下原点、y 向上）。
    ///   - baseFrame: 按下瞬间的窗口 frame（屏幕坐标），用来取固定的对角点。
    ///   - pressPoint: 按下瞬间指针的屏幕坐标（位于被拖的角上）。
    ///   - edge: 拖的是哪个角。
    ///   - imageAspect: 图片宽 / 高。
    /// - Returns: 目标高度（pt）。
    static func targetHeight(
        pointer: CGPoint,
        baseFrame: CGRect,
        pressPoint: CGPoint,
        edge: ResizeEdge,
        imageAspect: CGFloat
    ) -> CGFloat {
        guard imageAspect > 0, baseFrame.height > 0 else { return baseFrame.height }

        // 指针自按下以来的位移。x 方向按「远离 / 靠近固定边」取符号，
        // 保证向右拖右边、向左拖左边都是变大。
        let dx = (pointer.x - pressPoint.x) * (edge.touchesLeft ? -1 : 1)
        let dy = (pointer.y - pressPoint.y) * (edge.touchesTop ? -1 : 1)

        // 位移投影到对角线 (aspect, 1) 上，投影点的纵分量就是高度增量。
        //   Δh = (dx * aspect + dy) / (aspect² + 1)
        let aspectSquared = imageAspect * imageAspect
        let deltaHeight = (dx * imageAspect + dy) / (aspectSquared + 1)

        return baseFrame.height + deltaHeight
    }

    /// 四角缩放热区的**基准**边长（pt）。实际热区由 `cornerHitSize(in:)` 按尺寸自适应。
    static let cornerHitSize: CGFloat = 22
    /// 热区上限：大图上不要大到抢走抓手的区域。
    static let cornerHitSizeMax: CGFloat = 44

    /// 按贴图尺寸算出实际角热区边长。
    ///
    /// 固定值在小图上会盖满全图，在大图上又大到难以命中（用户会觉得「不在角上」）。
    /// 取短边的 18%，夹在 [22, 44] 之间：不管贴图多大，角上都是一个既抓得住、
    /// 又不会抢走边框的可见区域。
    static func cornerHitSize(in size: CGSize) -> CGFloat {
        let shorter = min(size.width, size.height)
        return min(max(shorter * 0.18, cornerHitSize), cornerHitSizeMax)
    }

    /// 指针落在哪里，决定光标和按下后的行为。
    ///
    /// 设计约束（来自实际使用反馈）：
    /// - **只有四个角**能缩放。四条边不再缩放：贴图常常紧贴屏幕边缘，
    ///   边上的热区会被屏幕边界截掉一半，命中不稳定。
    /// - **其余所有区域（四周边缘 + 内部）都是抓手**，整张贴图可以拖走。
    /// - **关闭按钮优先级最高**，它盖在右上角缩放热区之上，显示箭头。
    /// - 落在贴图之外根本收不到事件（窗口就这么大），所以「外面是正常箭头」
    ///   由窗口不接收事件自然得到；为了指针刚离开时立刻变回箭头，
    ///   `mouseExited` 里也要显式设回箭头。
    enum HitZone: Equatable {
        /// 关闭按钮：显示箭头，按下即关闭。
        case closeButton
        /// 四角缩放：显示对应方向的缩放箭头，按下拖拽等比缩放。
        case resize(ResizeEdge)
        /// 边缘与内部：抓手，按下拖动整块。
        case move

        /// 这个位置该显示的光标。
        var cursor: PointerCursor {
            switch self {
            case .closeButton: return .arrow
            case .move: return .openHand
            case .resize(let edge): return .resize(edge.axis)
            }
        }
    }

    /// 按优重次序判定指针落在哪个区：关闭按钮 → 四角 → 其余（抓手）。
    ///
    /// `point` 是视图坐标（`isFlipped`，左上原点、y 向下），与 `closeButtonCenter` 一致。
    static func hitZone(
        at point: CGPoint,
        in size: CGSize
    ) -> HitZone {
        if isOverCloseButton(point: point, size: size) {
            return .closeButton
        }
        let hitSize = cornerHitSize(in: size)
        // 贴图太小的时候缩放热区会盖满全图、抓不住，这时只给抓手。
        guard size.width > hitSize * 2, size.height > hitSize * 2 else {
            return .move
        }
        if let edge = corner(at: point, in: size) {
            return .resize(edge)
        }
        return .move
    }

    /// 只判定四个角（不认边）。热区边长按尺寸自适应，见 `cornerHitSize(in:)`。
    static func corner(
        at point: CGPoint,
        in size: CGSize
    ) -> ResizeEdge? {
        let hitSize = cornerHitSize(in: size)
        guard size.width > hitSize * 2, size.height > hitSize * 2 else { return nil }
        let nearLeft = point.x <= hitSize
        let nearRight = point.x >= size.width - hitSize
        let nearTop = point.y <= hitSize
        let nearBottom = point.y >= size.height - hitSize

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeading
        case (_, true, true, _): return .topTrailing
        case (true, _, _, true): return .bottomLeading
        case (_, true, _, true): return .bottomTrailing
        default: return nil
        }
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
