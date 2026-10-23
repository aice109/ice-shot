import AppKit
import CoreGraphics

/// 一个显示器的几何信息。
///
/// 两套坐标必须分清：
/// - `frame`：CoreGraphics 全局屏幕坐标，主屏左上角为原点、y 向下，单位 points。
/// - `appKitFrame`：AppKit 全局屏幕坐标，主屏左下角为原点、y 向上，单位 points。
///
/// 选区、捕获与像素转换都从这里取值，视图层不再自行换算。
struct DisplayDescriptor: Sendable, Identifiable, Hashable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let appKitFrame: CGRect
    let pointSize: CGSize
    let pixelSize: CGSize
    let scale: CGFloat
    let localizedName: String

    init(
        id: CGDirectDisplayID,
        frame: CGRect,
        appKitFrame: CGRect,
        scale: CGFloat,
        localizedName: String = ""
    ) {
        self.id = id
        self.frame = frame
        self.appKitFrame = appKitFrame
        self.pointSize = appKitFrame.size
        self.pixelSize = CGSize(
            width: (appKitFrame.width * scale).rounded(),
            height: (appKitFrame.height * scale).rounded()
        )
        self.scale = scale
        self.localizedName = localizedName
    }

    init?(screen: NSScreen, primaryMaxY: CGFloat) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(number.uint32Value)
        let appKitFrame = screen.frame
        let scale = screen.backingScaleFactor
        let cgFrame = ScreenGeometry.cgRect(fromAppKit: appKitFrame, primaryMaxY: primaryMaxY)

        self.init(
            id: displayID,
            frame: cgFrame,
            appKitFrame: appKitFrame,
            scale: scale,
            localizedName: screen.localizedName
        )
    }
}

/// 坐标转换与像素对齐的唯一入口。
enum ScreenGeometry {
    /// 主屏在 AppKit 中的最大 y。
    ///
    /// 不能用 `NSScreen.main`：它表示当前活动屏，不一定是主屏。
    static func primaryMaxY(screens: [NSScreen] = NSScreen.screens) -> CGFloat {
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return primary?.frame.maxY ?? 0
    }

    static func makeDescriptors(screens: [NSScreen] = NSScreen.screens) -> [DisplayDescriptor] {
        let maxY = primaryMaxY(screens: screens)
        return screens.compactMap { DisplayDescriptor(screen: $0, primaryMaxY: maxY) }
    }

    static func cgRect(fromAppKit rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func appKitRect(fromCG rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func displayLocalRect(fromCG rect: CGRect, display: DisplayDescriptor) -> CGRect {
        rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    static func cgPoint(fromDisplayLocal point: CGPoint, display: DisplayDescriptor) -> CGPoint {
        CGPoint(
            x: display.frame.minX + point.x,
            y: display.frame.minY + point.y
        )
    }

    static func displayLocalPoint(fromCG point: CGPoint, display: DisplayDescriptor) -> CGPoint {
        CGPoint(
            x: point.x - display.frame.minX,
            y: point.y - display.frame.minY
        )
    }

    static func displayLocalRect(fromPixel rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return .zero }
        return CGRect(
            x: rect.minX / scale,
            y: rect.minY / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }

    static func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    static func snapRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        let minX = snapToPixel(rect.minX, scale: scale)
        let minY = snapToPixel(rect.minY, scale: scale)
        let maxX = snapToPixel(rect.maxX, scale: scale)
        let maxY = snapToPixel(rect.maxY, scale: scale)
        let minimum = 1 / scale
        return CGRect(
            x: minX,
            y: minY,
            width: max(minimum, maxX - minX),
            height: max(minimum, maxY - minY)
        )
    }

    /// 将显示器局部 points 矩形转换成像素矩形。
    ///
    /// `CGImage.cropping(to:)` 使用图像左上原点，因此这里保持 y 向下，不做翻转。
    static func pixelRect(fromDisplayLocal rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return .zero }
        let minX = (rect.minX * scale).rounded()
        let minY = (rect.minY * scale).rounded()
        let maxX = (rect.maxX * scale).rounded()
        let maxY = (rect.maxY * scale).rounded()
        return CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }

    static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }
}
