import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 序号标注：自动递增、删中间不重排、撤销 / 重做保持自洽、圆心回夹画布内。
@MainActor
struct NumberAnnotationTests {
    private let style = AnnotationStyle(color: .defaultRed, lineWidth: 4, opacity: 1)

    @Test func numbersIncrementFromOne() throws {
        let model = EditorModel(image: try makeImage(width: 200, height: 120), title: "Test")
        #expect(model.nextNumber == 1)

        let first = model.addNumber(at: CGPoint(x: 30, y: 30))
        let second = model.addNumber(at: CGPoint(x: 60, y: 30))
        let third = model.addNumber(at: CGPoint(x: 90, y: 30))

        #expect(first.number == 1)
        #expect(second.number == 2)
        #expect(third.number == 3)
        #expect(model.nextNumber == 4)
        #expect(model.annotations.allSatisfy { $0.kind == .number })
    }

    @Test func deletingMiddleNumberDoesNotRenumber() throws {
        let model = EditorModel(image: try makeImage(width: 200, height: 120), title: "Test")
        model.addNumber(at: CGPoint(x: 30, y: 30))
        let second = model.addNumber(at: CGPoint(x: 60, y: 30))
        model.addNumber(at: CGPoint(x: 90, y: 30))

        model.delete(id: second.id)
        // 删掉 #2 之后：#1、#3 原样保留，新徽章取最大值 + 1。
        #expect(model.annotations.compactMap(\.number) == [1, 3])
        #expect(model.nextNumber == 4)
    }

    @Test func undoRestoresCounterAndRedoKeepsNumber() throws {
        let model = EditorModel(image: try makeImage(width: 200, height: 120), title: "Test")
        model.attachUndoManager(UndoManager())
        model.addNumber(at: CGPoint(x: 30, y: 30))
        model.addNumber(at: CGPoint(x: 60, y: 30))
        #expect(model.nextNumber == 3)

        model.undo()
        #expect(model.annotations.compactMap(\.number) == [1])
        #expect(model.nextNumber == 2)

        model.redo()
        #expect(model.annotations.compactMap(\.number) == [1, 2])
        #expect(model.nextNumber == 3)
    }

    @Test func numberCenterIsClampedInsideCanvas() throws {
        let model = EditorModel(image: try makeImage(width: 100, height: 80), title: "Test")
        let annotation = model.addNumber(at: CGPoint(x: 2, y: 2))
        let radius = annotation.numberDiameter / 2

        #expect(annotation.start.x == radius)
        #expect(annotation.start.y == radius)
        #expect(annotation.bounds.minX >= 0)
        #expect(annotation.bounds.minY >= 0)
        #expect(annotation.bounds.maxX <= 100)
        #expect(annotation.bounds.maxY <= 80)
    }

    @Test func numberBadgeUsesLineWidthForDiameter() {
        let small = EditorAnnotation(
            kind: .number,
            start: .zero,
            end: .zero,
            number: 1,
            style: AnnotationStyle(color: .defaultRed, lineWidth: 1, opacity: 1)
        )
        let large = EditorAnnotation(
            kind: .number,
            start: .zero,
            end: .zero,
            number: 1,
            style: AnnotationStyle(color: .defaultRed, lineWidth: 10, opacity: 1)
        )
        // 直径跟随线宽，但有 20 px 的下限。
        #expect(small.numberDiameter == 20)
        #expect(large.numberDiameter == 60)
        #expect(small.bounds.width == small.numberDiameter)
    }

    @Test func numberHitTestAndCroppingFollowCenter() throws {
        let model = EditorModel(image: try makeImage(width: 200, height: 200), title: "Test")
        let annotation = model.addNumber(at: CGPoint(x: 100, y: 100))
        let radius = annotation.numberDiameter / 2

        #expect(annotation.hitTest(CGPoint(x: 100, y: 100)))
        #expect(!annotation.hitTest(CGPoint(x: 100 + radius + 20, y: 100)))

        let remapped = AnnotationCropper.remap(
            [annotation],
            croppingTo: CGRect(x: 50, y: 50, width: 100, height: 100)
        )
        let cropped = try #require(remapped.first)
        #expect(cropped.start == CGPoint(x: 50, y: 50))
        #expect(cropped.number == 1)
    }

    @Test func rotationMovesNumberCenterAndKeepsItUpright() throws {
        let annotation = EditorAnnotation(
            kind: .number,
            start: CGPoint(x: 30, y: 40),
            end: CGPoint(x: 30, y: 40),
            number: 7,
            style: style
        )
        let rotated = AnnotationTransformer.rotated(
            [annotation],
            imageSize: CGSize(width: 100, height: 80),
            clockwise: true
        )
        let result = try #require(rotated.first)
        // (x, y) → (H - y, x) = (80 - 40, 30)
        #expect(result.start == CGPoint(x: 40, y: 30))
        #expect(result.number == 7)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(
            data: Data(count: width * height * 4) as CFData
        ) else {
            throw CaptureError.encodingFailed
        }
        guard let image = CGImage(
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
}
