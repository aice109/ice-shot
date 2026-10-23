import CoreGraphics
import Testing
@testable import IceShot

/// 工具 → 二级选项的映射，以及「同一份线宽」在各工具上的换算。
@MainActor
struct EditorToolOptionsTests {
    // MARK: - 映射

    @Test("选择与裁剪没有二级选项，点了不弹窗")
    func selectionAndCropHaveNoOptions() {
        #expect(EditorToolOptions(tool: .select).isPresented == false)
        #expect(EditorToolOptions(tool: .crop).isPresented == false)
    }

    @Test("绘图工具：颜色 + 线宽")
    func drawingToolsUseLineWidth() {
        for tool in [EditorTool.rectangle, .ellipse, .line, .arrow, .freehand] {
            let options = EditorToolOptions(tool: tool)
            #expect(options.showsColor)
            #expect(options.widthRole == .line)
            #expect(options.showsRedaction == false)
            #expect(options.isPresented)
        }
    }

    @Test("高亮 / 文字 / 序号各用自己的粗细角色，但共用同一个滑块")
    func specialisedToolsMapToTheirOwnRole() {
        #expect(EditorToolOptions(tool: .highlighter).widthRole == .highlighter)
        #expect(EditorToolOptions(tool: .text).widthRole == .fontSize)
        #expect(EditorToolOptions(tool: .number).widthRole == .badge)
    }

    @Test("马赛克工具：颜色 + 笔刷 + 样式与块大小（模糊只是它的样式）")
    func redactionToolShowsStyleControls() {
        let options = EditorToolOptions(tool: .pixelate)
        #expect(options.showsColor)
        #expect(options.widthRole == .brush)
        #expect(options.showsRedaction)

        // 选中已有打码标注时只留打码自己的参数（颜色 / 粗细是「新标注用什么」的语义）。
        #expect(EditorToolOptions.selectedRedaction.showsRedaction)
        #expect(EditorToolOptions.selectedRedaction.widthRole == nil)
        #expect(EditorToolOptions.selectedRedaction.showsColor == false)
    }

    // MARK: - 选中已有标注时的选项

    @Test("四种类型有选中态选项，其余没有")
    func selectedOptionsMapByKind() {
        #expect(EditorToolOptions.forKind(.text)?.showsTextBackground == true)
        #expect(EditorToolOptions.forKind(.pixelate)?.showsRedaction == true)
        #expect(EditorToolOptions.forKind(.blur)?.showsRedaction == true)
        #expect(EditorToolOptions.forKind(.spotlight)?.showsSpotlight == true)
        #expect(EditorToolOptions.forKind(.magnifier)?.showsMagnifier == true)

        for kind: AnnotationKind in [.rectangle, .ellipse, .line, .arrow, .freehand, .highlighter, .number] {
            #expect(EditorToolOptions.forKind(kind) == nil)
        }
    }

    @Test("选中态选项都不带颜色与粗细")
    func selectedOptionsDoNotDuplicateColorOrWidth() {
        for kind: AnnotationKind in [.text, .pixelate, .blur, .spotlight, .magnifier] {
            let options = EditorToolOptions.forKind(kind)
            #expect(options?.showsColor == false)
            #expect(options?.widthRole == nil)
        }
    }

    @Test("浮窗取值：指向选中标注时读那条标注，否则读默认值")
    func optionsReadFromSelectedAnnotation() throws {
        let model = try makeModel()
        model.setTool(.pixelate)
        model.setFilterAmount(24)
        // 没有选中标注时读的是「以后新标注用什么」。
        #expect(model.optionsFilterAmount == 24)

        let redaction = EditorAnnotation(
            kind: .pixelate,
            start: CGPoint(x: 5, y: 5),
            end: CGPoint(x: 20, y: 20),
            points: [CGPoint(x: 5, y: 5), CGPoint(x: 20, y: 20)],
            style: AnnotationStyle(
                color: .defaultRed,
                lineWidth: 16,
                opacity: 1,
                filterAmount: 8,
                redactionStyle: .noise
            )
        )
        model.add(redaction)
        model.select(redaction.id)
        model.setOptionsTarget(.selectedAnnotation)
        // 选中态读的是那条标注自己的值，不是默认值。
        #expect(model.optionsFilterAmount == 8)
        #expect(model.optionsRedactionStyle == .noise)

        // 关掉浮窗后回到默认值语义。
        model.setOptionsTarget(nil)
        #expect(model.optionsFilterAmount == 24)
        #expect(model.optionsRedactionStyle == .mosaic)
    }

    @Test("选中变化会通知外部（AppKit 工具栏靠它刷新按钮）")
    func selectionChangeNotifiesObserver() throws {
        let model = try makeModel()
        var count = 0
        model.onSelectionChange = { count += 1 }

        let annotation = EditorAnnotation(
            kind: .rectangle,
            start: .zero,
            end: CGPoint(x: 10, y: 10),
            style: AnnotationStyle(color: .defaultRed, lineWidth: 4, opacity: 1)
        )
        model.add(annotation)
        model.select(annotation.id)
        model.select(annotation.id)
        model.select(nil)
        #expect(count == 2)
    }

    // MARK: - 换算

    @Test("默认线宽翻倍后，各工具的实际像素值")
    func defaultWidthResolvesPerRole() throws {
        let width = try makeModel().lineWidth
        #expect(width == 8)
        #expect(EditorToolOptions.WidthRole.line.resolved(width) == 8)
        #expect(EditorToolOptions.WidthRole.highlighter.resolved(width) == 24)
        #expect(EditorToolOptions.WidthRole.fontSize.resolved(width) == 48)
        #expect(EditorToolOptions.WidthRole.badge.resolved(width) == 48)
        #expect(EditorToolOptions.WidthRole.brush.resolved(width) == 32)
    }

    @Test("最细档位仍保证可读下限")
    func minimumsKeepGlyphsReadable() {
        let width: CGFloat = 1
        #expect(EditorToolOptions.WidthRole.line.resolved(width) == 1)
        #expect(EditorToolOptions.WidthRole.highlighter.resolved(width) == 12)
        #expect(EditorToolOptions.WidthRole.fontSize.resolved(width) == 16)
        #expect(EditorToolOptions.WidthRole.badge.resolved(width) == 20)
        #expect(EditorToolOptions.WidthRole.brush.resolved(width) == 12)
    }

    @Test("读数显示换算后的真实值，不是滑块原始值")
    func valueLabelShowsResolvedPixels() {
        #expect(EditorToolOptions.WidthRole.line.valueLabel(8) == "8 px")
        #expect(EditorToolOptions.WidthRole.fontSize.valueLabel(8) == "48 px")
        #expect(EditorToolOptions.WidthRole.brush.valueLabel(8) == "32 px")
    }

    // MARK: - 模型

    @Test("粗细只有一份：改一次，各工具都跟着变")
    func lineWidthIsSharedAcrossTools() throws {
        let model = try makeModel()
        model.setLineWidth(12)

        model.setTool(.rectangle)
        #expect(model.activeStyle.lineWidth == 12)

        model.setTool(.highlighter)
        #expect(model.activeStyle.lineWidth == 36)

        model.setTool(.text)
        #expect(model.activeStyle.fontSize == 72)

        model.setTool(.pixelate)
        #expect(model.activeStyle.lineWidth == 48)
        #expect(model.lineWidth == 12)
    }

    @Test("线宽被限制在滑块范围内")
    func lineWidthClampsToRange() throws {
        let model = try makeModel()
        model.setLineWidth(0)
        #expect(model.lineWidth == EditorModel.lineWidthRange.lowerBound)
        model.setLineWidth(999)
        #expect(model.lineWidth == EditorModel.lineWidthRange.upperBound)
    }

    @Test("二级选项浮窗状态可开关，Esc 依赖它判断先关浮窗")
    func optionsTargetToggles() throws {
        let model = try makeModel()
        #expect(model.optionsTarget == nil)

        model.setOptionsTarget(.tool(.text))
        #expect(model.optionsTarget == .tool(.text))

        model.setOptionsTarget(.selectedAnnotation)
        #expect(model.optionsTarget == .selectedAnnotation)

        model.setOptionsTarget(nil)
        #expect(model.optionsTarget == nil)
    }

    // MARK: - 辅助

    private func makeModel() throws -> EditorModel {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 40,
            height: 40,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let image = try #require(context.makeImage())
        return EditorModel(image: image, title: "Test")
    }
}
