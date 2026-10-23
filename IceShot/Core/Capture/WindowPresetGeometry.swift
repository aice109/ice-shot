import CoreGraphics

/// 窗口截图进入就地编辑所需的几何：选区落在哪块屏、窗口图像要裁多少。
///
/// 纯计算，便于单元测试；窗口可能跨屏或被屏幕边缘截断。
struct WindowEditorGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    /// 选区在显示器局部坐标中的矩形（points，左上原点）。
    let displayLocalRect: CGRect
    /// 窗口图像上对应的像素矩形。
    let imagePixelRect: CGRect
}

enum WindowPresetGeometry {
    /// 计算窗口截图的编辑选区。
    ///
    /// 窗口超出屏幕时按屏幕裁切，保证选区与图像内容一致。
    static func make(
        windowFrame: CGRect,
        imageSize: CGSize,
        displays: [DisplayDescriptor]
    ) -> WindowEditorGeometry? {
        guard windowFrame.width >= 1, windowFrame.height >= 1,
              imageSize.width >= 1, imageSize.height >= 1,
              let display = bestDisplay(for: windowFrame, in: displays) else {
            return nil
        }

        let visible = windowFrame.intersection(display.frame)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            return nil
        }

        let scaleX = imageSize.width / windowFrame.width
        let scaleY = imageSize.height / windowFrame.height
        let pixel = CGRect(
            x: ((visible.minX - windowFrame.minX) * scaleX).rounded(),
            y: ((visible.minY - windowFrame.minY) * scaleY).rounded(),
            width: (visible.width * scaleX).rounded(),
            height: (visible.height * scaleY).rounded()
        )
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let clipped = pixel.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            return nil
        }

        return WindowEditorGeometry(
            displayID: display.id,
            displayLocalRect: visible.offsetBy(
                dx: -display.frame.minX,
                dy: -display.frame.minY
            ),
            imagePixelRect: clipped
        )
    }

    /// 系统表面（桌面 / 菜单栏）在显示器上的可见矩形（显示器局部 points，左上原点）。
    ///
    /// 这类窗口没有可靠的独立窗口图，截取时改用冻结帧按这个矩形裁切，
    /// 所以这里只需要几何：窗口被屏幕边缘截断时同样按屏幕裁剪。
    static func systemSurfaceRect(
        windowFrame: CGRect,
        display: DisplayDescriptor
    ) -> CGRect? {
        let visible = windowFrame.intersection(display.frame)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            return nil
        }
        return visible.offsetBy(
            dx: -display.frame.minX,
            dy: -display.frame.minY
        )
    }

    /// 与窗口相交面积最大的显示器；完全不相交时返回 nil。
    static func bestDisplay(
        for windowFrame: CGRect,
        in displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        var best: (display: DisplayDescriptor, area: CGFloat)?
        for display in displays {
            let intersection = display.frame.intersection(windowFrame)
            guard !intersection.isNull,
                  intersection.width >= 1,
                  intersection.height >= 1 else {
                continue
            }
            let area = intersection.width * intersection.height
            if let current = best {
                if area > current.area {
                    best = (display, area)
                }
            } else {
                best = (display, area)
            }
        }
        return best?.display
    }
}
