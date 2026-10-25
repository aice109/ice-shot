import CoreGraphics
import Testing
@testable import IceShot

/// 标注的「命中区」= 按下后真的会改到东西的范围。
///
/// 这条规则直接决定光标：命中 → 抓手，没命中 → 十字/箭头。
/// 因此「矩形的中间空白算不算命中」不是细节，是用户能不能理解画布的关键——
/// 曾经整框都算命中，光标在框中间显示抓手，拖一下却什么都没抓住。
struct AnnotationHitTestTests {
    private func make(
        _ kind: AnnotationKind,
        start: CGPoint = CGPoint(x: 100, y: 100),
        end: CGPoint = CGPoint(x: 300, y: 200),
        lineWidth: CGFloat = 3
    ) -> EditorAnnotation {
        EditorAnnotation(
            kind: kind,
            start: start,
            end: end,
            style: AnnotationStyle(color: .defaultRed, lineWidth: lineWidth, opacity: 1)
        )
    }

    // MARK: - 矩形：只有四条边

    @Test("矩形：四条边命中")
    func rectangleEdgesHit() {
        let rect = make(.rectangle)  // x 100–300, y 100–200
        #expect(rect.hitTest(CGPoint(x: 200, y: 100)), "上边")
        #expect(rect.hitTest(CGPoint(x: 200, y: 200)), "下边")
        #expect(rect.hitTest(CGPoint(x: 100, y: 150)), "左边")
        #expect(rect.hitTest(CGPoint(x: 300, y: 150)), "右边")
        #expect(rect.hitTest(CGPoint(x: 100, y: 100)), "左上角")
    }

    @Test("矩形：中间空白不命中")
    func rectangleInteriorMisses() {
        let rect = make(.rectangle)
        #expect(!rect.hitTest(CGPoint(x: 200, y: 150)), "正中心")
        #expect(!rect.hitTest(CGPoint(x: 150, y: 120)), "内侧左上")
        #expect(!rect.hitTest(CGPoint(x: 250, y: 180)), "内侧右下")
    }

    @Test("矩形：外侧容差内仍可命中，超出就不行")
    func rectangleOuterTolerance() {
        let rect = make(.rectangle)
        #expect(rect.hitTest(CGPoint(x: 200, y: 95)), "上边外 5pt")
        #expect(!rect.hitTest(CGPoint(x: 200, y: 60)), "上边外 40pt")
    }

    // MARK: - 椭圆：只有周长

    @Test("椭圆：周长命中，内部空白不命中")
    func ellipseEdgeOnly() {
        let ellipse = make(.ellipse)  // 中心 (200,150)，半径 100 × 50
        #expect(ellipse.hitTest(CGPoint(x: 300, y: 150)), "右顶点")
        #expect(ellipse.hitTest(CGPoint(x: 200, y: 100)), "上顶点")
        #expect(!ellipse.hitTest(CGPoint(x: 200, y: 150)), "正中心空白")
        #expect(!ellipse.hitTest(CGPoint(x: 260, y: 150)), "内部靠右空白")
    }

    @Test("椭圆：框角不属于椭圆（不是矩形判定）")
    func ellipseIgnoresBoundingBoxCorner() {
        let ellipse = make(.ellipse)
        // 外接矩形的角 (100,100)：椭圆本体内侧，但不该被当成命中。
        #expect(!ellipse.hitTest(CGPoint(x: 105, y: 105)))
    }

    // MARK: - 线 / 箭头：只有线段

    @Test("直线：线段命中，两侧远处不命中")
    func lineSegment() {
        let line = make(.line)
        #expect(line.hitTest(CGPoint(x: 200, y: 150)), "线段中点")
        #expect(!line.hitTest(CGPoint(x: 200, y: 190)))
    }

    // MARK: - 实心区域类：整框命中

    @Test("文字 / 序号 / 聚光灯 / 放大镜：整框命中")
    func solidKindsHitWholeBounds() {
        // 文字：命中区是**文字实际所占的框**（`textBoxRect`），不是 start/end 包围盒。
        let text = EditorAnnotation(
            kind: .text,
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 300, y: 200),
            text: "测试文字",
            style: AnnotationStyle(color: .defaultRed, lineWidth: 3, opacity: 1)
        )
        #expect(text.hitTest(CGPoint(x: 110, y: 110)), "文字框内")
        #expect(!text.hitTest(CGPoint(x: 900, y: 900)), "远离文字框")
        // 聚光灯：框内是亮区（不变），框外压暗——命中区就是亮区。
        #expect(make(.spotlight).hitTest(CGPoint(x: 200, y: 150)), "聚光灯亮区")
        // 放大镜：框内有内容。
        #expect(make(.magnifier).hitTest(CGPoint(x: 200, y: 150)), "放大镜框内")

        // 序号是圆形徽章，命中按圆心半径算（见 `NumberAnnotationTests`），
        // 不是外接矩形；这里只确认圆心能命中。
        let badge = EditorAnnotation(
            kind: .number,
            start: CGPoint(x: 200, y: 150),
            end: CGPoint(x: 200, y: 150),
            number: 1,
            style: AnnotationStyle(color: .defaultRed, lineWidth: 3, opacity: 1)
        )
        #expect(badge.hitTest(CGPoint(x: 200, y: 150)), "序号圆心")
    }

    // MARK: - 退化输入

    @Test("宽或高为 0 的矩形不会崩，也不误判")
    func degenerateRectangle() {
        let flat = make(.rectangle, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 100))
        // 高度 0 实际上就是一条线，边上命中、远处不命中。
        #expect(flat.hitTest(CGPoint(x: 200, y: 100)))
        #expect(!flat.hitTest(CGPoint(x: 400, y: 400)))
    }

    @Test("极小的椭圆不会误判整块")
    func tinyEllipse() {
        let tiny = make(.ellipse, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 102, y: 102))
        #expect(tiny.hitTest(CGPoint(x: 101, y: 101)))
        #expect(!tiny.hitTest(CGPoint(x: 200, y: 200)))
    }
}
