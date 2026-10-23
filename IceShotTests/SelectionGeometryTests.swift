import CoreGraphics
import Testing
@testable import IceShot

/// 选区几何：反向拖拽归一化、Shift 锁比例、Option 居中扩展与像素对齐。
@MainActor
struct SelectionGeometryTests {
    @Test func reverseDragProducesNormalizedRect() {
        let rect = SelectionGeometry.rect(
            from: CGPoint(x: 300, y: 400),
            to: CGPoint(x: 100, y: 50),
            lockAspect: false,
            fromCenter: false
        )
        #expect(rect == CGRect(x: 100, y: 50, width: 200, height: 350))
    }

    @Test func shiftLocksSquareUsingLargerDelta() {
        let rect = SelectionGeometry.rect(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 260, y: 180),
            lockAspect: true,
            fromCenter: false
        )
        #expect(rect == CGRect(x: 100, y: 100, width: 160, height: 160))
    }

    @Test func shiftKeepsDirectionForReverseDrag() {
        let rect = SelectionGeometry.rect(
            from: CGPoint(x: 300, y: 300),
            to: CGPoint(x: 160, y: 220),
            lockAspect: true,
            fromCenter: false
        )
        #expect(rect == CGRect(x: 160, y: 160, width: 140, height: 140))
    }

    @Test func optionExpandsFromCenter() {
        let rect = SelectionGeometry.rect(
            from: CGPoint(x: 200, y: 200),
            to: CGPoint(x: 260, y: 240),
            lockAspect: false,
            fromCenter: true
        )
        #expect(rect == CGRect(x: 140, y: 160, width: 120, height: 80))
    }

    @Test func shiftAndOptionProduceCenteredSquare() {
        let rect = SelectionGeometry.rect(
            from: CGPoint(x: 200, y: 200),
            to: CGPoint(x: 260, y: 230),
            lockAspect: true,
            fromCenter: true
        )
        #expect(rect == CGRect(x: 140, y: 140, width: 120, height: 120))
    }

    @Test func shiftResizeCornerKeepsAspectRatio() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let resized = SelectionGeometry.resized(
            rect: rect,
            handle: .bottomRight,
            to: CGPoint(x: 250, y: 300),
            lockAspect: true
        )
        #expect(resized == CGRect(x: 100, y: 100, width: 400, height: 200))
    }

    @Test func shiftResizeTopLeftKeepsAspectRatioAndAnchor() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let resized = SelectionGeometry.resized(
            rect: rect,
            handle: .topLeft,
            to: CGPoint(x: 50, y: 50),
            lockAspect: true
        )
        #expect(resized == CGRect(x: 0, y: 50, width: 300, height: 150))
    }

    @Test func shiftResizeEdgeKeepsAspectRatioCentered() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

        let right = SelectionGeometry.resized(
            rect: rect,
            handle: .right,
            to: CGPoint(x: 400, y: 150),
            lockAspect: true
        )
        #expect(right == CGRect(x: 100, y: 75, width: 300, height: 150))

        let top = SelectionGeometry.resized(
            rect: rect,
            handle: .top,
            to: CGPoint(x: 200, y: 50),
            lockAspect: true
        )
        #expect(top == CGRect(x: 50, y: 50, width: 300, height: 150))
    }

    @Test func resizeWithoutShiftUsesFreeEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let resized = SelectionGeometry.resized(
            rect: rect,
            handle: .bottomRight,
            to: CGPoint(x: 400, y: 300),
            lockAspect: false
        )
        #expect(resized == CGRect(x: 100, y: 100, width: 300, height: 200))
    }
}
