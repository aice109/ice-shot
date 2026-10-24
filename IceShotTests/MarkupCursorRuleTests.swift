import Testing
@testable import IceShot

/// 标注画布的光标规则。
///
/// 这些用例锁的是 `docs/ui-guidelines.md` 里「标注画布的光标」那张表——
/// 改任一格都必须同时改测试与文档，三处不一致就会被这里拦住。
struct MarkupCursorRuleTests {
    private func cursor(
        _ tool: EditorTool,
        inside: Bool = true,
        overAnnotation: Bool = false,
        dragging: Bool = false,
        movingAnnotation: Bool = false
    ) -> PointerCursor {
        MarkupCursorRule.cursor(for: .init(
            tool: tool,
            isInsideImage: inside,
            isOverAnnotation: overAnnotation,
            isDragging: dragging,
            isMovingAnnotation: movingAnnotation
        ))
    }

    // MARK: - 拖拽中

    @Test("拖动已有标注 = 抓紧")
    func draggingAnnotationShowsClosedHand() {
        for tool in EditorTool.allCases where tool != .crop {
            #expect(cursor(tool, dragging: true, movingAnnotation: true) == .closedHand)
        }
    }

    @Test("画新东西 = 十字，不随指针经过其它标注而变")
    func drawingShowsCrosshair() {
        #expect(cursor(.rectangle, overAnnotation: true, dragging: true) == .crosshair)
        #expect(cursor(.freehand, dragging: true) == .crosshair)
    }

    // MARK: - 悬停已有标注

    @Test("任何工具下悬停已有标注都是手形")
    func hoverAnnotationShowsOpenHand() {
        let tools: [EditorTool] = [
            .select, .rectangle, .ellipse, .line, .arrow, .freehand,
            .highlighter, .number, .pixelate, .spotlight, .magnifier
        ]
        for tool in tools {
            #expect(cursor(tool, overAnnotation: true) == .openHand)
        }
    }

    @Test("文字工具悬停已有文字是 I-beam：点它是进编辑，不是拖动")
    func textToolHoveringTextShowsIBeam() {
        #expect(cursor(.text, overAnnotation: true) == .iBeam)
    }

    // MARK: - 图上空白

    @Test("绘制类工具在图上空白处都是十字")
    func drawingToolsShowCrosshair() {
        let tools: [EditorTool] = [
            .rectangle, .ellipse, .line, .arrow, .freehand,
            .highlighter, .number, .pixelate, .spotlight, .magnifier
        ]
        for tool in tools {
            #expect(cursor(tool) == .crosshair)
        }
    }

    @Test("文字工具在图上空白处是 I-beam")
    func textToolShowsIBeam() {
        #expect(cursor(.text) == .iBeam)
    }

    @Test("无工具态在图上空白处是箭头：那里确实没有特殊动作")
    func selectToolShowsArrow() {
        #expect(cursor(.select) == .arrow)
    }

    // MARK: - 图外

    @Test("图外一律箭头，不显示任何可绘制 / 可拖动的暗示")
    func outsideImageShowsArrow() {
        for tool in EditorTool.allCases {
            #expect(cursor(tool, inside: false) == .arrow)
        }
    }
}
