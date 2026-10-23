import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import IceShot

/// 光标映射与边缘热区：两边都必须「用户看到的小方块 = 给出提示的位置」。
@MainActor
struct PointerCursorTests {
    // MARK: - 方向 → 系统光标

    @Test func cornerAxesAreCornersAndEdgesAreNot() {
        #expect(ResizeAxis.topLeading.isCorner)
        #expect(ResizeAxis.bottomTrailing.isCorner)
        #expect(!ResizeAxis.top.isCorner)
        #expect(!ResizeAxis.trailing.isCorner)
    }

    @Test func everyAxisHasDistinctSystemCursor() {
        for axis in ResizeAxis.allCases {
            let cursor = axis.system
            // 任何方向都不能退化成箭头（那就是「可缩放却没提示」）。
            #expect(cursor !== NSCursor.arrow)
            // 同一方向反复取，必须是同一个系统光标。
            #expect(cursor === axis.system)

            // 同轴的两个方向用同一个双向箭头（上 / 下都是上下箭头、左上 = 右下同一条斜向），
            // 这是系统语义；但**换轴必须换光标**，否则拖左边和拖上边提示一样。
            if let opposite = axis.opposite, axis.sharesCursor(with: opposite) {
                #expect(cursor === opposite.system)
            }

            // 角不能被降级成相邻的直线边箭头（角是斜向箭头）。
            if axis.isCorner, let edges = axis.adjacentEdges {
                for edge in edges {
                    #expect(cursor !== edge.system)
                }
            }
        }
    }

    @Test func resizingStateKeepsSameArrowAsResize() {
        for axis in ResizeAxis.allCases {
            #expect(PointerCursor.resize(axis).system === PointerCursor.resizing(axis).system)
        }
    }

    @Test func plainCursorsMapToSystemCursors() {
        #expect(PointerCursor.arrow.system === NSCursor.arrow)
        // 贴图内容区走手形（“整块可挪”）。AppKit 没有公开的四向移动箭头，
        // 手形才是系统里的可拖动语义。
        #expect(PointerCursor.move.system === NSCursor.openHand)
        #expect(PointerCursor.openHand.system === NSCursor.openHand)
        #expect(PointerCursor.closedHand.system === NSCursor.closedHand)
    }

    // MARK: - 热区判定

    private let rect = CGRect(x: 100, y: 100, width: 300, height: 200)

    @Test func handlesAreHitAtTheirCenters() {
        #expect(ResizeHitZone.axis(at: CGPoint(x: 100, y: 100), in: rect) == .topLeading)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 400, y: 100), in: rect) == .topTrailing)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 100, y: 300), in: rect) == .bottomLeading)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 400, y: 300), in: rect) == .bottomTrailing)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 250, y: 100), in: rect) == .top)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 250, y: 300), in: rect) == .bottom)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 100, y: 200), in: rect) == .leading)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 400, y: 200), in: rect) == .trailing)
    }

    @Test func cornerWinsOverEdgeNearTheCorner() {
        // 角点右下 6 pt：距角 6、距上边中点 144，必须判为角。
        #expect(ResizeHitZone.axis(at: CGPoint(x: 106, y: 106), in: rect) == .topLeading)
        // 上边中点附近仍是边。
        #expect(ResizeHitZone.axis(at: CGPoint(x: 250, y: 104), in: rect) == .top)
    }

    @Test func centerIsNotAResizeZone() {
        #expect(ResizeHitZone.axis(at: CGPoint(x: 250, y: 200), in: rect) == nil)
        // 刚出热区一点也应该是 nil，避免「整块都能缩」。
        #expect(ResizeHitZone.axis(at: CGPoint(x: 250, y: 120), in: rect) == nil)
    }

    @Test func edgeBandBetweenHandlesGivesDirection() {
        // 上边、避开中点与角的一段（中点 ±radius 之外）。
        #expect(ResizeHitZone.axis(at: CGPoint(x: 180, y: 101), in: rect) == .top)
        // 左边同理。
        #expect(ResizeHitZone.axis(at: CGPoint(x: 401, y: 160), in: rect) == .trailing)
        // 带外（离边 10 pt）不给提示。
        #expect(ResizeHitZone.axis(at: CGPoint(x: 180, y: 110), in: rect) == nil)
    }

    @Test func tinyRectStillHitsCorners() {
        // 框再小，四个角也必须能拿到缩放光标（只是没有了边带）。
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 0, y: 0), in: tiny) == .topLeading)
        #expect(ResizeHitZone.axis(at: CGPoint(x: 20, y: 20), in: tiny) == .bottomTrailing)
    }

    @Test func selectionHandleMapsToSameAxis() {
        // 选区的 `ResizeHandle` 与统一的 `ResizeAxis` 必须一一对应，
        // 否则会出现「拖左上角手柄却显示右下箭头」。
        for handle in ResizeHandle.allCases {
            let position = handle.position(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            let expected: ResizeAxis
            switch handle {
            case .topLeft: expected = .topLeading
            case .top: expected = .top
            case .topRight: expected = .topTrailing
            case .right: expected = .trailing
            case .bottomRight: expected = .bottomTrailing
            case .bottom: expected = .bottom
            case .bottomLeft: expected = .bottomLeading
            case .left: expected = .leading
            }
            #expect(handle.axis == expected)
            // 热区判定在同一个位置必须给出同一个方向。
            #expect(
                ResizeHitZone.axis(at: position, in: CGRect(x: 0, y: 0, width: 100, height: 100))
                    == expected
            )
        }
    }

    @Test func emptyRectHasNoZone() {
        #expect(ResizeHitZone.axis(at: .zero, in: .zero) == nil)
    }
}
