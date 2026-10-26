import CoreGraphics
import Foundation

/// 滚动长截图的拼接器：纯像素逻辑，可单测。
///
/// 算法：把「已拼接结果的底部条带」当作模板，在当前帧里竖直搜索最小灰度差位置，
/// 得到画面向上滚动的位移；位移之后的部分就是新内容，追加到结果底部。
/// 全程 1:1 像素、不缩放，接缝处不会因为重采样发糊。
///
/// 限制：帧尺寸必须一致；位移超过帧高 70% 视为跳变（滚太快 / 内容剧变）拒绝，
/// 由调用方提示用户慢一点，而不是拼出一张错位的图。
struct ScrollStitcher {
    enum Outcome: Equatable {
        /// 向下滚动：新内容追加在底部；`offset` 是本次位移。
        case appended(offset: Int, totalHeight: Int)
        /// 向上滚动：新内容插在顶部；`offset` 是本次位移。
        case prepended(offset: Int, totalHeight: Int)
        /// 与上一帧相同（没滚动），未追加。
        case duplicate
        /// 位移过大或内容变化太快，无法可靠匹配。
        case rejectedJump
        /// 已达到高度上限，未继续追加。
        case limitReached(totalHeight: Int)
    }

    /// 匹配用的重叠带高度（像素）。
    static let overlapBand = 120
    /// 允许的最大位移比例。
    static let maximumOffsetRatio = 0.7
    /// 拼接结果的像素总量上限（约 160 MB），避免超宽区域在内存里爆掉。
    static let maximumPixelCount = 40_000_000
    /// 绝对高度上限。
    static let maximumHeightLimit = 20_000

    let width: Int
    let frameHeight: Int
    let maximumHeight: Int
    let overlapBand: Int

    private(set) var totalHeight = 0
    private var pixels: [UInt8] = []
    private var grayscale: [UInt8] = []
    private var hasFirstFrame = false
    /// 首帧还没有被任何后续帧匹配过。
    ///
    /// 起采瞬间可能抓到窗口切换 / 台前调度滑入动画里的过渡帧（桌面、半截窗口）。
    /// 这种帧一旦被当作基线，后面每一帧真实内容都会判成跳变，整段采集作废。
    private var baseUnconfirmed = false

    init?(width: Int, frameHeight: Int) {
        let cap = min(
            ScrollStitcher.maximumHeightLimit,
            max(frameHeight, ScrollStitcher.maximumPixelCount / max(width, 1))
        )
        self.init(width: width, frameHeight: frameHeight, maximumHeight: cap)
    }

    /// 指定高度上限的初始化（单测用来验证「到达上限」的路径）。
    init?(width: Int, frameHeight: Int, maximumHeight: Int) {
        guard width > 8, frameHeight > ScrollStitcher.overlapBand * 2 else {
            return nil
        }
        guard maximumHeight > frameHeight else { return nil }
        self.width = width
        self.frameHeight = frameHeight
        self.overlapBand = ScrollStitcher.overlapBand
        self.maximumHeight = maximumHeight
        pixels.reserveCapacity(width * 4 * frameHeight * 4)
        grayscale.reserveCapacity(width * frameHeight * 4)
    }

    var isAtLimit: Bool {
        totalHeight >= maximumHeight
    }

    /// 追加一帧。
    mutating func append(_ image: CGImage) -> Outcome {
        guard image.width == width, image.height == frameHeight else {
            return .rejectedJump
        }
        guard let rendered = Self.render(image) else {
            return .rejectedJump
        }

        guard hasFirstFrame else {
            hasFirstFrame = true
            baseUnconfirmed = true
            appendRows(from: rendered, range: 0..<frameHeight)
            return .appended(offset: 0, totalHeight: totalHeight)
        }

        // 同时尝试两个方向：底部条带命中 = 向下滚，顶部条带命中 = 向上滚。
        let downward = matchBand(isTop: false, in: rendered.gray)
        let upward = matchBand(isTop: true, in: rendered.gray)

        switch (downward, upward) {
        case (nil, nil):
            // 首帧还没被确认过：内容对不上说明它不是稳定画面，直接换基线。
            // 只有「已拼过至少一处」之后，对不上才按滚动太快处理。
            guard baseUnconfirmed else {
                return .rejectedJump
            }
            replaceBase(with: rendered)
            return .appended(offset: 0, totalHeight: totalHeight)
        case (.some(let down), nil):
            return appendDownward(offset: down.offset, from: rendered)
        case (nil, .some(let up)):
            return prependUpward(offset: up.offset, from: rendered)
        case (.some(let down), .some(let up)):
            // 两个方向都像时取差异更小的；同分优先向下（最常见的滚动方向）。
            return up.difference < down.difference
                ? prependUpward(offset: up.offset, from: rendered)
                : appendDownward(offset: down.offset, from: rendered)
        }
    }

    /// 向下滚动：把位移之后的部分追加到结果底部。
    private mutating func appendDownward(
        offset scrollOffset: Int,
        from rendered: (rgba: [UInt8], gray: [UInt8])
    ) -> Outcome {
        let newRowStart = scrollOffset + overlapBand
        guard newRowStart < frameHeight else {
            return .duplicate
        }
        let available = frameHeight - newRowStart
        let room = maximumHeight - totalHeight
        if room <= 0 {
            return .limitReached(totalHeight: totalHeight)
        }
        // 真的拼进了新内容，基线才算被确认；只是重复帧不算。
        baseUnconfirmed = false
        if available > room {
            appendRows(from: rendered, range: newRowStart..<(newRowStart + room))
            return .limitReached(totalHeight: totalHeight)
        }
        appendRows(from: rendered, range: newRowStart..<frameHeight)
        return .appended(offset: scrollOffset, totalHeight: totalHeight)
    }

    /// 向上滚动：把位移之前的部分插到结果顶部。
    private mutating func prependUpward(
        offset: Int,
        from rendered: (rgba: [UInt8], gray: [UInt8])
    ) -> Outcome {
        guard offset > 0 else {
            return .duplicate
        }
        let room = maximumHeight - totalHeight
        if room <= 0 {
            return .limitReached(totalHeight: totalHeight)
        }
        // 真的拼进了新内容，基线才算被确认；只是重复帧不算。
        baseUnconfirmed = false
        if offset > room {
            // 只保留最靠近已拼内容的 `room` 行，避免超上限。
            prependRows(from: rendered, range: (offset - room)..<offset)
            return .limitReached(totalHeight: totalHeight)
        }
        prependRows(from: rendered, range: 0..<offset)
        return .prepended(offset: offset, totalHeight: totalHeight)
    }

    /// 当前拼接结果；超过 `maximumHeight` 的部分不会存在缓冲里。
    func makeImage() -> CGImage? {
        guard totalHeight > 0 else { return nil }
        let byteCount = width * 4 * totalHeight
        let data = Data(pixels.prefix(byteCount)) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - 匹配

    /// 在 `frame` 里找「结果底部条带」出现的位置；匹配失败返回 nil。
    ///
    /// 两级搜索：先在 1/4 分辨率上遍历所有位置（抗噪、算量小），
    /// 再回到原分辨率在最优值 ±4 内细化。整块内容被替换（跳变、切窗口）时
    /// 最小差仍然很大 → 返回 nil，由调用方提示用户慢一点。
    private func matchBand(isTop: Bool, in frame: [UInt8]) -> (offset: Int, difference: Int)? {
        guard totalHeight >= overlapBand else { return nil }
        let needleStart = isTop ? 0 : totalHeight - overlapBand
        let maxOffset = frameHeight - overlapBand
        guard maxOffset > 0 else { return nil }

        let needle = downsample(
            grayscale,
            startRow: needleStart,
            rowCount: overlapBand
        )
        let coarse = downsample(frame, startRow: 0, rowCount: frameHeight)

        var bestCoarseOffset = 0
        var bestCoarseDifference = Int.max
        let coarseSlack = max(1, needle.sampleCount)
        for offset in 0...(coarse.height - needle.height) {
            let difference = Self.difference(
                needle: needle,
                needleOffset: 0,
                frame: coarse,
                frameOffset: offset
            )
            if difference < bestCoarseDifference {
                bestCoarseDifference = difference
                bestCoarseOffset = offset
            } else if difference <= bestCoarseDifference + coarseSlack,
                      offset > bestCoarseOffset {
                // 画面大面积同色时多个位置都几乎相等：取最靠下的那个，
                // 这样「没滚动」会被判成重复帧，而不是把同样的内容再拼一遍。
                bestCoarseOffset = offset
            }
        }

        let anchor = bestCoarseOffset * Self.downsampleFactor
        var bestOffset = min(max(anchor, 0), maxOffset)
        var bestDifference = Int.max
        let slack = bandSampleCount
        let lower = max(0, anchor - Self.downsampleFactor)
        let upper = min(maxOffset, anchor + Self.downsampleFactor)
        for offset in lower...upper {
            let difference = bandDifference(
                needleStart: needleStart,
                frameOffset: offset,
                frame: frame
            )
            if difference < bestDifference {
                bestDifference = difference
                bestOffset = offset
            } else if difference <= bestDifference + slack, offset > bestOffset {
                bestOffset = offset
            }
        }

        let samples = bandSampleCount
        guard samples > 0 else { return nil }
        let average = bestDifference / samples
        guard average <= Self.differenceThreshold else { return nil }
        // 向上滚时位移同样不能超过帧高 70%。
        guard bestOffset <= maxOffset else { return nil }
        return (bestOffset, average)
    }

    /// 平均灰度差的阈值（0…255）。
    private static let differenceThreshold = 8

    /// 采样步长：横向 4 像素、纵向 4 行，既够稳又快。
    private static let xStep = 4
    private static let yStep = 4
    /// 粗搜索的降采样倍率。
    private static let downsampleFactor = 4

    private var bandSampleCount: Int {
        let xs = (width + Self.xStep - 1) / Self.xStep
        let ys = (overlapBand + Self.yStep - 1) / Self.yStep
        return max(1, xs * ys)
    }

    /// 1/4 分辨率的灰度块（每块取 4×4 均值）。
    private struct Downsampled {
        let width: Int
        let height: Int
        let values: [UInt8]

        var sampleCount: Int { max(1, width * height) }
    }

    private func downsample(_ gray: [UInt8], startRow: Int, rowCount: Int) -> Downsampled {
        let factor = Self.downsampleFactor
        let outWidth = max(1, width / factor)
        let outHeight = max(1, rowCount / factor)
        var values = [UInt8](repeating: 0, count: outWidth * outHeight)

        for outRow in 0..<outHeight {
            for outColumn in 0..<outWidth {
                var sum = 0
                var count = 0
                for dy in 0..<factor {
                    let row = startRow + outRow * factor + dy
                    guard row < startRow + rowCount else { continue }
                    let rowStart = row * width
                    for dx in 0..<factor {
                        let column = outColumn * factor + dx
                        guard column < width else { continue }
                        sum += Int(gray[rowStart + column])
                        count += 1
                    }
                }
                values[outRow * outWidth + outColumn] = count > 0
                    ? UInt8(sum / count)
                    : 0
            }
        }
        return Downsampled(width: outWidth, height: outHeight, values: values)
    }

    private static func difference(
        needle: Downsampled,
        needleOffset: Int,
        frame: Downsampled,
        frameOffset: Int
    ) -> Int {
        var difference = 0
        for row in 0..<needle.height {
            let needleRow = (needleOffset + row) * needle.width
            let frameRow = (frameOffset + row) * frame.width
            for column in 0..<needle.width {
                difference += abs(
                    Int(needle.values[needleRow + column]) - Int(frame.values[frameRow + column])
                )
            }
        }
        return difference
    }

    private func bandDifference(needleStart: Int, frameOffset: Int, frame: [UInt8]) -> Int {
        var difference = 0
        var row = 0
        while row < overlapBand {
            let needleRow = (needleStart + row) * width
            let frameRow = (frameOffset + row) * width
            var column = 0
            while column < width {
                difference += abs(
                    Int(grayscale[needleRow + column]) - Int(frame[frameRow + column])
                )
                column += Self.xStep
            }
            row += Self.yStep
        }
        return difference
    }

    // MARK: - 缓冲

    /// 用当前帧换掉还没被确认的首帧。
    private mutating func replaceBase(with rendered: (rgba: [UInt8], gray: [UInt8])) {
        pixels.removeAll(keepingCapacity: true)
        grayscale.removeAll(keepingCapacity: true)
        totalHeight = 0
        appendRows(from: rendered, range: 0..<frameHeight)
    }

    private mutating func appendRows(
        from rendered: (rgba: [UInt8], gray: [UInt8]),
        range: Range<Int>
    ) {
        let bytesPerRow = width * 4
        for row in range {
            pixels.append(contentsOf: rendered.rgba[(row * bytesPerRow)..<((row + 1) * bytesPerRow)])
            grayscale.append(contentsOf: rendered.gray[(row * width)..<((row + 1) * width)])
        }
        totalHeight += range.count
    }

    private mutating func prependRows(
        from rendered: (rgba: [UInt8], gray: [UInt8]),
        range: Range<Int>
    ) {
        let bytesPerRow = width * 4
        var pixelPrefix: [UInt8] = []
        var grayPrefix: [UInt8] = []
        pixelPrefix.reserveCapacity(range.count * bytesPerRow)
        grayPrefix.reserveCapacity(range.count * width)
        for row in range {
            pixelPrefix.append(contentsOf: rendered.rgba[(row * bytesPerRow)..<((row + 1) * bytesPerRow)])
            grayPrefix.append(contentsOf: rendered.gray[(row * width)..<((row + 1) * width)])
        }
        pixels.insert(contentsOf: pixelPrefix, at: 0)
        grayscale.insert(contentsOf: grayPrefix, at: 0)
        totalHeight += range.count
    }

    private static func render(_ image: CGImage) -> (rgba: [UInt8], gray: [UInt8])? {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var gray = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let r = Int(rgba[index * 4])
            let g = Int(rgba[index * 4 + 1])
            let b = Int(rgba[index * 4 + 2])
            gray[index] = UInt8((r * 77 + g * 151 + b * 28) >> 8)
        }
        return (rgba, gray)
    }
}
