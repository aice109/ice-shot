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
        overAnnotation: Bool = false,
        movingAnnotation: Bool = false,
        overToolbar: Bool = false,
        tool: EditorTool? = nil
    ) -> PointerCursor {
        SelectionCursorRule.cursor(for: .init(
            pointer: pointer,
            selection: selection ?? self.selection,
            isSpacePressed: space,
            isMovingSelection: moving,
            isHoveringWindows: hoveringWindows,
            isCreatingSelection: creating,
            isOverAnnotation: overAnnotation,
            isMovingAnnotation: movingAnnotation,
            isOverToolbar: overToolbar,
            markupTool: tool
        ))
    }

    // MARK: - 区域划分（用户口径的唯一来源）

    @Test("操作条：永远正常箭头——即使它压在暗区上、甚至挡着边框")
    func toolbarAlwaysArrow() {
        // 压在暗区上
        #expect(cursor(pointer: CGPoint(x: 20, y: 700), overToolbar: true) == .arrow)
        // 压在边框上（工具栏贴边时会发生）
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 1, y: selection.midY),
                       overToolbar: true) == .arrow)
        // 选了什么工具都一样
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), overToolbar: true, tool: .rectangle)
            == .arrow)
    }

    @Test("暗区：选区外一律禁止，与工具无关")
    func darkAreaIsNotAllowed() {
        for tool: EditorTool? in [nil, .select, .rectangle, .text] {
            for point in [CGPoint(x: 5, y: 5), CGPoint(x: 600, y: 600),
                          CGPoint(x: 200, y: 400), CGPoint(x: 700, y: 175)] {
                #expect(cursor(pointer: point, tool: tool) == .notAllowed)
            }
        }
    }

    @Test("边框：四边四角按方向给缩放，且右 / 下边界线（半开区间的死区）也算")
    func borderGivesResize() {
        #expect(cursor(pointer: CGPoint(x: selection.midX, y: selection.minY)) == .resizing(.top))
        // maxY / maxX 正是 `CGRect.contains` 判 false 的地方，必须照样算边框。
        #expect(cursor(pointer: CGPoint(x: selection.midX, y: selection.maxY)) == .resizing(.bottom))
        #expect(cursor(pointer: CGPoint(x: selection.minX, y: selection.midY)) == .resizing(.leading))
        #expect(cursor(pointer: CGPoint(x: selection.maxX, y: selection.midY)) == .resizing(.trailing))
        #expect(cursor(pointer: CGPoint(x: selection.minX, y: selection.minY)) == .resizing(.topLeading))
        #expect(cursor(pointer: CGPoint(x: selection.maxX, y: selection.maxY)) == .resizing(.bottomTrailing))
    }

    @Test("整条边都能拉，不只是边中点——否则真机上只有四个角可拉")
    func wholeEdgeIsResizable() {
        // 沿右边从角到角取样，每一格都必须是缩放（含内侧几 pt）。
        let samples: [CGFloat] = [0.25, 0.4, 0.5, 0.6, 0.75]
        for ratio in samples {
            let y = selection.minY + selection.height * ratio
            #expect(cursor(pointer: CGPoint(x: selection.maxX - 3, y: y)) == .resizing(.trailing),
                    "右edge y=\(ratio)")
            #expect(cursor(pointer: CGPoint(x: selection.minX + 3, y: y)) == .resizing(.leading),
                    "左edge y=\(ratio)")
        }
        let xs: [CGFloat] = [0.25, 0.4, 0.5, 0.6, 0.75]
        for ratio in xs {
            let x = selection.minX + selection.width * ratio
            #expect(cursor(pointer: CGPoint(x: x, y: selection.maxY - 3)) == .resizing(.bottom),
                    "下边 x=\(ratio)")
            #expect(cursor(pointer: CGPoint(x: x, y: selection.minY + 3)) == .resizing(.top),
                    "上边 x=\(ratio)")
        }
    }

    @Test("截图区域：选择态箭头，文本 I，其余工具十字")
    func screenshotAreaFollowsTool() {
        let center = CGPoint(x: 200, y: 175)
        #expect(cursor(pointer: center, tool: .select) == .arrow)
        #expect(cursor(pointer: center, tool: nil) == .arrow)
        #expect(cursor(pointer: center, tool: .text) == .iBeam)
        for tool: EditorTool in [.rectangle, .ellipse, .line, .arrow, .freehand,
                                 .highlighter, .number, .pixelate, .spotlight, .magnifier] {
            #expect(cursor(pointer: center, tool: tool) == .crosshair, "\(tool.rawValue)")
        }
    }

    @Test("绘制区域优先于「内部按工具」：画着矩形时移到旧矩形边框上也是抓手")
    func drawnAreaBeatsTool() {
        let center = CGPoint(x: 200, y: 175)
        #expect(cursor(pointer: center, overAnnotation: true, tool: .rectangle) == .openHand)
        // 但边框仍优先于绘制区：贴着选区边时给缩放，方便调范围。
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 1, y: selection.midY),
                       overAnnotation: true) == .resizing(.trailing))
    }

    // MARK: - 悬停已有标注

    @Test("悬停已有标注 = 抓手，任何工具下都一样")
    func hoverAnnotationShowsOpenHand() {
        let center = CGPoint(x: 200, y: 175)
        for tool: EditorTool in [.select, .rectangle, .ellipse, .line, .arrow,
                                 .freehand, .highlighter, .number, .pixelate,
                                 .spotlight, .magnifier] {
            #expect(cursor(pointer: center, overAnnotation: true, tool: tool) == .openHand,
                    "\(tool.rawValue)")
        }
    }

    @Test("文字工具悬停已有文字 = 文本 I（那一下是进编辑，不是拖动）")
    func hoverTextWithTextToolShowsIBeam() {
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), overAnnotation: true, tool: .text)
            == .iBeam)
    }

    @Test("拖动已有标注全程抓紧，优先于四边四角的缩放")
    func movingAnnotationStaysClosedHand() {
        let onEdge = CGPoint(x: selection.maxX - 1, y: selection.midY)
        #expect(cursor(pointer: onEdge, movingAnnotation: true, tool: .select) == .closedHand)
        #expect(cursor(pointer: onEdge, movingAnnotation: true, tool: .rectangle) == .closedHand)
    }

    // MARK: - 选中工具后的内部口径

    @Test("绘制工具：选区内空白处十字，但贴边仍让位给缩放")
    func markupToolUsesCrosshairInsideSelection() {
        let center = CGPoint(x: 200, y: 175)
        let tools: [EditorTool] = [
            .rectangle, .ellipse, .line, .arrow, .freehand,
            .highlighter, .number, .pixelate, .spotlight, .magnifier
        ]
        for tool in tools {
            #expect(cursor(pointer: center, tool: tool) == .crosshair, "\(tool.rawValue)")
        }
        // 边缘手柄带跨边界，与工具无关：贴着边的内侧也是缩放，避免一格窄带里光标来回跳。
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 2, y: selection.midY), tool: .rectangle)
            == .resizing(.trailing))
        #expect(cursor(pointer: CGPoint(x: selection.minX + 1, y: selection.minY + 1), tool: .rectangle)
            == .resizing(.topLeading))
    }

    @Test("选择态：内部箭头，四边四角缩放——与绘制工具只差「内部」")
    func selectToolShowsArrowInsideAndResizeOnEdge() {
        // 内部（离边够远）= 箭头。回归守卫：曾因边缘判定把内部也推成缩放。
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), tool: .select) == .arrow)
        // 贴边（含内侧）= 缩放，与全局一致。
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 2, y: selection.midY), tool: .select)
            == .resizing(.trailing))
        #expect(cursor(pointer: CGPoint(x: selection.minX + 1, y: selection.minY + 1), tool: .select)
            == .resizing(.topLeading))
    }

    @Test("文本工具：选区内为文本 I，贴边让位给缩放")
    func textToolUsesIBeamInsideSelection() {
        #expect(cursor(pointer: CGPoint(x: 200, y: 175), tool: .text) == .iBeam)
        // 边缘手柄带与工具无关，文字工具贴边同样是缩放。
        #expect(cursor(pointer: CGPoint(x: selection.maxX - 2, y: selection.midY), tool: .text)
            == .resizing(.trailing))
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
