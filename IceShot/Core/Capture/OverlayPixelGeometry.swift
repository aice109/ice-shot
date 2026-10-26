import CoreGraphics

/// 浮层选区（显示器局部 points）→ 模型图（像素）的唯一换算。
///
/// 浮层的模型图在两种场景下含义不同：
/// - 区域截图：模型图是整块冻结帧，选区只是它上面的一个窗口；
/// - 窗口 / 全屏 / 重复区域：模型图就是预设选区的图。
///
/// 两种都能用「选区相对 imageFrame 的偏移 × 图/框比例」算出来。最终输出与带壳预览
/// 必须走同一个函数，否则用户会看到「预览裁得对，导出却偏一截」。
enum OverlayPixelGeometry {
    static func pixelRect(
        selection: CGRect,
        imageFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard imageFrame.width > 0,
              imageFrame.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return nil
        }

        let scaleX = imageSize.width / imageFrame.width
        let scaleY = imageSize.height / imageFrame.height
        let pixel = CGRect(
            x: ((selection.minX - imageFrame.minX) * scaleX).rounded(),
            y: ((selection.minY - imageFrame.minY) * scaleY).rounded(),
            width: (selection.width * scaleX).rounded(),
            height: (selection.height * scaleY).rounded()
        )
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clipped = pixel.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            return nil
        }
        return clipped
    }
}
