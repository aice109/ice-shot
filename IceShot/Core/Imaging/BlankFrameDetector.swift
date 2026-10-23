import CoreGraphics

/// 判断一张截图是否「基本没有任何内容」。
///
/// 场景：用 `SCContentFilter(desktopIndependentWindow:)` 抓一个没有独立可截内容的系统
/// overlay（例如通知横幅）时，得到的是「窗口本体不透明 + 其余区域全透明」的图。
/// 这种图当成功返回会一路进编辑器、写历史，用户看到的只是一张空白图。
/// 所以先在抓取出口拦下。
enum BlankFrameDetector {
    /// 有内容的最低不透明像素占比。
    ///
    /// 真正的窗口截图几乎整张不透明；一个横幅规模的 overlay 只有个位数百分比。
    /// 取 5% 够宽松，不会误杀大量留白 / 圆角的正常窗口。
    static let minimumOpaqueRatio: Double = 0.05

    /// 按固定步长采样估算不透明像素占比；`0...1`。
    ///
    /// 采样而非逐像素，是为了让 4K 全屏图也只做几万次读取。
    static func opaqueRatio(_ image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0 }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // 拿不到像素时不能断言「空白」，否则会把正常截图误判成失败。
            return 1
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let step = max(1, (width * height) / 40_000)
        var sampled = 0
        var opaque = 0
        var index = 0
        while index < width * height {
            if data[index * 4 + 3] > 8 {
                opaque += 1
            }
            sampled += 1
            index += step
        }
        guard sampled > 0 else { return 0 }
        return Double(opaque) / Double(sampled)
    }

    static func isBlank(_ image: CGImage) -> Bool {
        opaqueRatio(image) < minimumOpaqueRatio
    }
}
