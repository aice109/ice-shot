import CoreGraphics
import Testing
@testable import IceShot

/// 操作条布局：两个入口（截图浮层 / 编辑器窗口）共用同一份按钮清单与顺序，
/// 差异只允许通过 `MarkupToolbarLayout.Context` 显式表达。
///
/// 这些用例锁的是「用户看到的两个入口长得一样」这件事——按钮漏了、顺序变了、
/// 某个按钮在某个入口莫名消失，都会在这里失败。
@MainActor
struct MarkupToolbarLayoutTests {
    // MARK: - 工具清单

    @Test("浮层不含裁剪：选区本身就是裁剪范围")
    func overlayHasNoCropTool() {
        #expect(!MarkupToolbarLayout.tools(showsCropTool: false).contains(.crop))
        #expect(MarkupToolbarLayout.tools(showsCropTool: false).count
            == EditorTool.allCases.filter(\.appearsOnToolbar).count - 1)
    }

    @Test("编辑器窗口含裁剪")
    func editorHasCropTool() {
        #expect(MarkupToolbarLayout.tools(showsCropTool: true) == EditorTool.allCases.filter(\.appearsOnToolbar))
        #expect(MarkupToolbarLayout.tools(showsCropTool: true).contains(.crop))
    }

    @Test("工具顺序沿用 allCases，不因过滤改变相对顺序")
    func toolOrderFollowsAllCases() {
        let expected = EditorTool.allCases.filter { $0.appearsOnToolbar && $0 != .crop }
        #expect(MarkupToolbarLayout.tools(showsCropTool: false) == expected)
    }

    @Test("「选择」是无工具哨兵，永远不出现在操作条上")
    func selectNeverAppearsOnToolbar() {
        // 它没有 `annotationKind`，只是「当前不画东西」的内部状态。
        // 它的图标（`cursorarrow`）与箭头工具（`arrow.up.right`）太像，放到操作条上会让人分不清。
        #expect(EditorTool.select.appearsOnToolbar == false)
        #expect(!MarkupToolbarLayout.tools(showsCropTool: true).contains(.select))
        #expect(!MarkupToolbarLayout.tools(showsCropTool: false).contains(.select))
        for group in EditorTool.Group.allCases {
            #expect(EditorTool.tools(in: group).filter(\.appearsOnToolbar).contains(.select) == false)
        }
    }

    @Test("增强组在浮层里有工具，不该被隐藏")
    func enhancementGroupIsVisible() {
        #expect(MarkupToolbarLayout.shows(.enhancement, showsCropTool: false))
        #expect(MarkupToolbarLayout.shows(.drawing, showsCropTool: false))
    }

    // MARK: - 按钮清单

    @Test("浮层：有图取字与关闭，没有变换与选中态选项（默认无选中）")
    func overlayItems() {
        let items = MarkupToolbarLayout.items(
            in: .overlay,
            showsCropTool: false,
            hasSelectedAnnotationOptions: false
        )
        #expect(items.contains(.textPicking))
        #expect(items.contains(.close))
        #expect(!items.contains(.transform))
        #expect(!items.contains(.selectedOptions))
    }

    @Test("编辑器：有变换，没有关闭（关闭走标题栏与 ⌘W）")
    func editorItems() {
        let items = MarkupToolbarLayout.items(
            in: .editor,
            showsCropTool: true,
            hasSelectedAnnotationOptions: false
        )
        #expect(items.contains(.transform))
        #expect(!items.contains(.close))
    }

    @Test("选中态有参数时两处都出现那个选项按钮")
    func selectedOptionsAppearsInBothContexts() {
        for context in [MarkupToolbarLayout.Context.overlay, .editor] {
            let items = MarkupToolbarLayout.items(
                in: context,
                showsCropTool: context == .editor,
                hasSelectedAnnotationOptions: true
            )
            #expect(items.contains(.selectedOptions))
        }
    }

    @Test("输出组四项固定顺序：撤销 / 重做 / 复制 / 保存 / 贴图")
    func actionOrderIsStable() {
        for context in [MarkupToolbarLayout.Context.overlay, .editor] {
            let items = MarkupToolbarLayout.items(
                in: context,
                showsCropTool: context == .editor,
                hasSelectedAnnotationOptions: false
            )
            let expected = MarkupToolbarLayout.actionCluster.filter {
                $0 != .close || context == .overlay
            }
            #expect(items.suffix(expected.count).map { $0 } == expected)
        }
    }

    @Test("工具组总是排在动作组之前")
    func toolsComeBeforeActions() {
        let items = MarkupToolbarLayout.items(
            in: .editor,
            showsCropTool: true,
            hasSelectedAnnotationOptions: true
        )
        let lastToolIndex = items.lastIndex(of: .selectedOptions) ?? -1
        let firstActionIndex = items.firstIndex(of: .undo) ?? -1
        #expect(lastToolIndex >= 0)
        #expect(firstActionIndex > lastToolIndex)
    }

    // MARK: - 变换

    @Test("变换四项齐全，图标与快捷键都不重复")
    func transformsAreComplete() {
        let all = MarkupToolbarLayout.Transform.allCases
        #expect(all.count == 4)
        #expect(Set(all.map(\.symbolName)).count == all.count)
        #expect(Set(all.map(\.shortcut)).count == all.count)
        #expect(all.allSatisfy { !$0.title.isEmpty })
    }

    @Test("变换浮窗同样登记为二级选项，Esc 能先关掉它")
    func transformIsAnOptionsTarget() throws {
        let model = EditorModel(image: try TestImages.solid(width: 24, height: 16), title: "t")
        #expect(model.optionsTarget == nil)
        model.setOptionsTarget(.transform)
        #expect(model.optionsTarget == .transform)
        model.setOptionsTarget(nil)
        #expect(model.optionsTarget == nil)
    }
}

/// 测试用的纯白 `CGImage`：只关心尺寸与可读像素，不关心内容。
enum TestImages {
    static func solid(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
