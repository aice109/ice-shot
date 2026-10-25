import AppKit
import CoreGraphics
import Testing
@testable import IceShot

/// 浮层选区阶段的光标：锁 `docs/ui-guidelines.md` 的「浮层选区阶段」那张表。
///
/// 这张表以前在真机上最容易错：框选完成后指针没动，十字准星就留在了屏幕上；
/// 指针离开选区，抓手也不收。这里逐格锁住「这里该是什么」。
@MainActor
struct SelectionCursorRuleTests {
    private let selection = CGRect(x: 100, y: 100, width: 200, height: 150)

    private func cursor(
        pointer: CGPoint?,
        selection: CGRect? = nil,
        space: Bool = false,
        moving: Bool = false,
        hoveringWindows: Bool = false,
        creating: Bool = false,
        tool: EditorTool? = nil
    ) -> PointerCursor {
        SelectionCursorRule.cursor(for: .init(
            pointer: pointer,
            selection: selection ?? self.selection,
            isSpacePressed: space,
            isMovingSelection: moving,
            isHoveringWindows: hoveringWindows,
            isCreatingSelection: creating,
            markupTool: tool
        ))
    }

    // MARK: - 选中工具后的内部口径

    @Test("选中绘制工具后，选区内一律十字（包括边缘与角）")
    func markupToolUsesCrosshairInsideSelection() {
        let center = CGPoint(x: 200, y: 175)
        let tools: [EditorTool] = [
            .rectangle, .ellipse, .line, .arrow, .freehand,
            .highlighter, .number, .pixelate, .spotlight, .magnifier
        ]
        for tool in tools {
            #expect(cursor(pointer: center, tool: tool) == .crosshair, "\(tool.rawValue)")
        }
        // 边缘让位：工具亮着时不再抢缩放箭头。
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 2, y: selection.midY), tool: .rectangle)
            == .crosshair)
        #expect(cursor(pointer: CGPoint(x: selection.minX + 1, y: selection.minY + 1), tool: .rectangle)
            == .crosshair)
    }

    @Test("选中文本工具后，选区内为文本 I")
    func textToolUsesIBeamInsideSelection() {
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), tool: .text) == .iBeam)
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 2, y: selection.midY), tool: .text)
            == .iBeam)
    }

    @Test("选中工具后，选区外仍然禁止、无工具态仍然缩放（与全局一致）")
    func toolDoesNotChangeOuterBehaviour() {
        // 选区外：一律禁止，不管选了什么工具。
        #expect(cursor(pointer: CGPoint(x: 5, y: 5), tool: .rectangle) == .notAllowed)
        #expect(cursor(pointer: CGPoint(x: 600, y: 600), tool: .text) == .notAllowed)
        // 无工具态：边缘仍是缩放箭头。
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 2, y: selection.midY)) == .resizing(.trailing))
    }

    // MARK: - 框选之后

    @Test("框选完成后，指针停在选区内部 = 箭头，不是十字")
    func insideSelectionShowsArrow() {
        #expect(cursor(pointer: CGPoint(x: 200, y: 175)) == .arrow)
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), space: false) == .arrow)
    }

    @Test("指针在选区内 = 箭头；出选区 = 禁止；贴边 = 缩放箭头")
    func selectionAndOutsideCursors() {
        // 选区中心 → 箭头（那里没有动作，但也不是「无效」）。
        #expect(cursor(pointer: CGPoint(x: 200, y: 175)) == .arrow)
        // 贴到右边中段 = 左右缩放。
        #expect(cursor(pointer: CGPoint(x: 298, y: 175)) == .resizing(.trailing))
        // 离开边缘热区但仍在选区内 → 箭头。
        #expect(cursor(pointer: CGPoint(x: 260, y: 175)) == .arrow)
        // 移到选区外 → 禁止（对齐微信截图）。
        #expect(cursor(pointer: CGPoint(x: 50, y: 175)) == .notAllowed)
        #expect(cursor(pointer: CGPoint(x: 200, y: 20)) == .notAllowed)
        #expect(cursor(pointer: CGPoint(x: 900, y: 900)) == .notAllowed)
    }

    @Test("拉框拖到选区外不显示禁止：那是本意，不是无效操作")
    func creatingSelectionIgnoresOutside() {
        #expect(cursor(pointer: CGPoint(x: 50, y: 50), creating: true) == .crosshair)
        #expect(cursor(pointer: CGPoint(x: 900, y: 900), creating: true) == .crosshair)
        // 指针跑到别的屏幕上时也不报禁止。
        #expect(cursor(pointer: nil, creating: true) == .arrow)
    }

    @Test("禁止光标在选区外仍然让位给缩放箭头：贴着边缘时优先显示能做什么")
    func edgeBeatsNotAllowed() {
        for point in [
            CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100),
            CGPoint(x: 100, y: 250), CGPoint(x: 300, y: 250),
        ] {
            let result = cursor(pointer: point)
            if case .resizing = result {} else {
                Issue.record("边角点 \(point) 应为缩放箭头，实际 \(result)")
            }
        }
    }

    @Test("四个角是斜向缩放，四条边是轴向缩放")
    func edgesAndCornersGiveResizeCursor() {
        #expect(cursor(pointer: CGPoint(x: 102, y: 102)) == .resizing(.topLeading))
        #expect(cursor(pointer: CGPoint(x: 300, y: 102)) == .resizing(.topTrailing))
        #expect(cursor(pointer: CGPoint(x: 102, y: 250)) == .resizing(.bottomLeading))
        #expect(cursor(pointer: CGPoint(x: 300, y: 250)) == .resizing(.bottomTrailing))
        #expect(cursor(pointer: CGPoint(x: 200, y: 101)) == .resizing(.top))
        #expect(cursor(pointer: CGPoint(x: 200, y: 249)) == .resizing(.bottom))
        #expect(cursor(pointer: CGPoint(x: 101, y: 175)) == .resizing(.leading))
    }

    @Test("热区只在边缘几 pt 内，不会把整条边都变成缩放区")
    func edgeToleranceIsTight() {
        let rect = selection
        // 距边 4 pt 以内算贴边，超过就不算。
        #expect(SelectionCursorRule.axis(at: CGPoint(x: rect.maxX - 3, y: rect.midY),
                                         selection: rect) == .trailing)
        #expect(SelectionCursorRule.axis(at: CGPoint(x: rect.maxX - 8, y: rect.midY),
                                         selection: rect) == nil)
    }

    // MARK: - 指针不在 / 还没框选

    @Test("指针不在本屏 = 箭头")
    func pointerOffDisplayShowsArrow() {
        #expect(cursor(pointer: nil) == .arrow)
    }

    @Test("还没框选 = 十字：这一阶段整屏的动作就是拉框 / 点窗口")
    func noSelectionShowsCrosshair() {
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), selection: .zero) == .crosshair)
        #expect(cursor(pointer: nil, selection: .zero, hoveringWindows: true) == .crosshair)
    }

    // MARK: - Space 拖移

    @Test("Space + 拖动中 = 抓紧，松手回到原判定")
    func spaceDraggingShowsClosedHand() {
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), space: true, moving: true) == .closedHand)
        // 拖动中被拖到屏幕外也是抓紧，松手前不跳。
        #expect(cursor(pointer: nil, space: true, moving: true) == .closedHand)
        // Space 按住且指针在选区内 = 可抓取的抓手；松手回箭头。
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), space: true, moving: false) == .openHand)
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), space: false, moving: false) == .arrow)
    }

    @Test("按住 Space 时，即使是绘制工具也要给抓手")
    func spaceBeatsMarkupTool() {
        // 以前工具态在 Space 之前判，导致按住 Space 也出不来抓手，
        // 而 Space 正是「整个选区可以拖」的唯一入口。
        for tool in [EditorTool.rectangle, .ellipse, .freehand, .text] {
            #expect(
                cursor(pointer: CGPoint(x: 200, y: 175), space: true, tool: tool) == .openHand,
                "\(tool.rawValue) + Space 应为抓手"
            )
        }
    }

    @Test("按住 Space 时边缘也让位给抓手（不再抢缩放箭头）")
    func spaceBeatsEdgeResize() {
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 2, y: selection.midY), space: true)
            == .openHand)
        #expect(cursor(pointer: CGPoint(x: selection.minX + 1, y: selection.minY + 1), space: true)
            == .openHand)
    }

    @Test("按住 Space 也拖不动选区外")
    func spaceDoesNotAllowOutsideSelection() {
        #expect(cursor(pointer: CGPoint(x: 5, y: 5), space: true) == .notAllowed)
    }

    // MARK: - 与标注画布不打架

    @Test("边缘光标绝不是十字：选区边缘归手柄，画布不该在那里画东西")
    func edgeCursorIsNeverCrosshair() {
        let points = [
            CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100),
            CGPoint(x: 100, y: 250), CGPoint(x: 300, y: 250),
            CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 250),
            CGPoint(x: 100, y: 175), CGPoint(x: 300, y: 175),
        ]
        for point in points {
            let result = SelectionCursorRule.cursor(for: .init(
                pointer: point,
                selection: selection,
                isSpacePressed: false,
                isMovingSelection: false,
                isHoveringWindows: false,
                isCreatingSelection: false
            ))
            #expect(result != .crosshair)
            if case .resizing = result {} else {
                Issue.record("边缘点 \(point) 应给出缩放箭头，实际 \(result)")
            }
        }
    }
}
