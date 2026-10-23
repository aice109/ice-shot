import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 拼接算法：用合成图做像素级验证（已知位移、重复帧、跳变、高度上限）。
@MainActor
struct ScrollStitcherTests {
    private let width = 300
    private let frameHeight = 500
    private let scrollDelta = 300

    @Test func stitchesOverlappingFramesIntoOriginalImage() throws {
        let source = try makeStrip(height: 1700)
        var stitcher = try #require(ScrollStitcher(width: width, frameHeight: frameHeight))

        var outcomes: [ScrollStitcher.Outcome] = []
        for offset in stride(from: 0, through: 1200, by: scrollDelta) {
            let frame = try ImageCropper.crop(
                source,
                to: CGRect(x: 0, y: offset, width: width, height: frameHeight)
            )
            outcomes.append(stitcher.append(frame))
        }

        #expect(outcomes.count == 5)
        #expect(outcomes.allSatisfy { if case .appended = $0 { return true }; return false })
        // 500 + 300 × 4 = 1700，与源图等高。
        #expect(stitcher.totalHeight == 1700)

        let stitched = try #require(stitcher.makeImage())
        #expect(stitched.width == width)
        #expect(stitched.height == 1700)
        #expect(try maxChannelDifference(stitched, source) <= 1)
    }

    /// 向上滚（内容从上方进入）同样要能拼：新内容插在顶部。
    @Test func stitchesUpwardScrollingByPrepending() throws {
        let source = try makeStrip(height: 1700)
        var stitcher = try #require(ScrollStitcher(width: width, frameHeight: frameHeight))

        var outcomes: [ScrollStitcher.Outcome] = []
        for offset in stride(from: 1200, through: 0, by: -scrollDelta) {
            let frame = try ImageCropper.crop(
                source,
                to: CGRect(x: 0, y: offset, width: width, height: frameHeight)
            )
            outcomes.append(stitcher.append(frame))
        }

        #expect(outcomes.count == 5)
        #expect(outcomes.dropFirst().allSatisfy {
            if case .prepended = $0 { return true }
            return false
        })
        #expect(stitcher.totalHeight == 1700)

        let stitched = try #require(stitcher.makeImage())
        #expect(stitched.height == 1700)
        #expect(try maxChannelDifference(stitched, source) <= 1)
    }

    /// 向下滚一段再向上滚回已拼过的区域：没有新内容，应当判为重复帧而不是重复拼接。
    @Test func scrollingBackIntoCapturedAreaIsDuplicate() throws {
        let source = try makeStrip(height: 1700)
        var stitcher = try #require(ScrollStitcher(width: width, frameHeight: frameHeight))
        for offset in [0, 300] {
            let frame = try ImageCropper.crop(
                source,
                to: CGRect(x: 0, y: offset, width: width, height: frameHeight)
            )
            _ = stitcher.append(frame)
        }
        let height = stitcher.totalHeight

        let back = try ImageCropper.crop(
            source,
            to: CGRect(x: 0, y: 0, width: width, height: frameHeight)
        )
        #expect(stitcher.append(back) == .duplicate)
        #expect(stitcher.totalHeight == height)
    }

    @Test func identicalFrameIsDuplicate() throws {
        let source = try makeStrip(height: 1700)
        var stitcher = try #require(ScrollStitcher(width: width, frameHeight: frameHeight))
        let first = try ImageCropper.crop(
            source,
            to: CGRect(x: 0, y: 0, width: width, height: frameHeight)
        )

        _ = stitcher.append(first)
        let height = stitcher.totalHeight
        #expect(stitcher.append(first) == .duplicate)
        #expect(stitcher.totalHeight == height)
    }

    @Test func bigJumpIsRejected() throws {
        let source = try makeStrip(height: 1700)
        var stitcher = try #require(ScrollStitcher(width: width, frameHeight: frameHeight))
        _ = stitcher.append(try ImageCropper.crop(
            source,
            to: CGRect(x: 0, y: 0, width: width, height: frameHeight)
        ))

        // 一次滚了 600 px（超过帧高 70% = 350），重叠带已经不在新帧里。
        let jumped = try ImageCropper.crop(
            source,
            to: CGRect(x: 0, y: 600, width: width, height: frameHeight)
        )
        #expect(stitcher.append(jumped) == .rejectedJump)
        #expect(stitcher.totalHeight == frameHeight)
    }

    @Test func stopsAtMaximumHeight() throws {
        let source = try makeStrip(height: 1700)
        var stitcher = try #require(ScrollStitcher(
            width: width,
            frameHeight: frameHeight,
            maximumHeight: 900
        ))

        var sawLimit = false
        for offset in stride(from: 0, through: 1200, by: scrollDelta) {
            let frame = try ImageCropper.crop(
                source,
                to: CGRect(x: 0, y: offset, width: width, height: frameHeight)
            )
            if case .limitReached(let height) = stitcher.append(frame) {
                #expect(height == 900)
                sawLimit = true
                break
            }
        }
        #expect(sawLimit)
        #expect(stitcher.totalHeight == 900)
    }

    @Test func mismatchedFrameSizeIsRejected() throws {
        let source = try makeStrip(height: 1700)
        var stitcher = try #require(ScrollStitcher(width: width, frameHeight: frameHeight))
        _ = stitcher.append(try ImageCropper.crop(
            source,
            to: CGRect(x: 0, y: 0, width: width, height: frameHeight)
        ))

        let wrong = try ImageCropper.crop(
            source,
            to: CGRect(x: 0, y: 300, width: 200, height: 400)
        )
        #expect(stitcher.append(wrong) == .rejectedJump)
    }

    // MARK: - 合成图

    /// 生成一张「每行都不重复」的竖向条纹图，避免匹配算法被重复纹理误导。
    private func makeStrip(height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            // 行内固定色，行与行之间用两套不同周期的函数区分，保证每行唯一。
            let r = UInt8((row * 7) % 251)
            let g = UInt8((row * 13 + 40) % 241)
            let b = UInt8((row * 29 + 90) % 233)
            for column in 0..<width {
                let index = (row * width + column) * 4
                let stripe = UInt8((column / 7) % 2 == 0 ? 0 : 24)
                bytes[index] = r
                bytes[index + 1] = UInt8(min(255, Int(g) + Int(stripe)))
                bytes[index + 2] = b
                bytes[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw CaptureError.encodingFailed
        }
        return image
    }

    private func maxChannelDifference(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
        let a = try rgbaBytes(lhs)
        let b = try rgbaBytes(rhs)
        guard a.count == b.count else { return 255 }
        var maximum = 0
        for index in a.indices {
            maximum = max(maximum, abs(Int(a[index]) - Int(b[index])))
        }
        return maximum
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard drawn else { throw CaptureError.encodingFailed }
        return bytes
    }
}
