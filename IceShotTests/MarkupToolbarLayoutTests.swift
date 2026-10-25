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
        #expect(MarkupToolbarLayout.tools(showsCropTool: true).contains(.crop))
    }

    @Test("独占一格的工具：选择 / 裁剪 / 箭头 / 文字 / 马赛克")
    func standaloneToolsAreExactlyFour() {
        #expect(MarkupToolbarLayout.tools(showsCropTool: true)
            == [.select, .crop, .arrow, .text, .pixelate])
        #expect(MarkupToolbarLayout.tools(showsCropTool: false) == [.select, .arrow, .text, .pixelate])
    }

    @Test("「选择」占操作条第一格：它是看得见、点得到的显式退出路径")
    func selectIsFirstAndAlwaysPresent() {
        #expect(MarkupToolbarLayout.tools(showsCropTool: true).first == .select)
        #expect(MarkupToolbarLayout.tools(showsCropTool: false).first == .select)
        // 它不属任何组，否则会被组按钮吞掉。
        for group in EditorTool.ToolGroup.allCases {
            #expect(!group.members.contains(.select))
        }
        #expect(EditorTool.select.toolGroup == nil)
    }

    @Test("组按钮：形状 / 画笔 / 更多 都出现")
    func allGroupsAppear() {
        #expect(MarkupToolbarLayout.groups(showsCropTool: false) == [.shape, .brush, .more])
        #expect(MarkupToolbarLayout.groups(showsCropTool: true) == [.shape, .brush, .more])
    }

    @Test("每个组都有可显示的工具，不会出现空组按钮")
    func noGroupIsEmpty() {
        for group in EditorTool.ToolGroup.allCases {
            #expect(MarkupToolbarLayout.shows(group, showsCropTool: false))
            #expect(!group.members.isEmpty)
        }
    }

    // MARK: - 按钮清单

    @Test("工具胶囊顺序：选择 → 裁剪 → 形状 → 箭头 → 画笔 → 文字 → 马赛克 → 取字 → 变换 → 更多")
    func toolClusterOrder() {
        let items = MarkupToolbarLayout.items(
            in: .editor,
            showsCropTool: true,
            hasSelectedAnnotationOptions: false
        )
        #expect(items == [
            .tool(.select),
            .tool(.crop),
            .group(.shape),
            .tool(.arrow),
            .group(.brush),
            .tool(.text),
            .tool(.pixelate),
            .textPicking,
            .transform,
            .group(.more)
        ])
    }

    @Test("浮层：没有裁剪与变换，选中态无参数时也没有选项按钮")
    func overlayItems() {
        let items = MarkupToolbarLayout.items(
            in: .overlay,
            showsCropTool: false,
            hasSelectedAnnotationOptions: false
        )
        #expect(!items.contains(.tool(.crop)))
        #expect(items.first == .tool(.select))
        #expect(!items.contains(.transform))
        #expect(!items.contains(.selectedOptions))
        #expect(items.contains(.textPicking))
        #expect(MarkupToolbarLayout.outputItems(in: .overlay).contains(.close))
    }

    @Test("编辑器：有变换，没有关闭（关闭走标题栏与 ⌘W）")
    func editorItems() {
        let items = MarkupToolbarLayout.items(
            in: .editor,
            showsCropTool: true,
            hasSelectedAnnotationOptions: false
        )
        #expect(items.contains(.transform))
        #expect(!MarkupToolbarLayout.outputItems(in: .editor).contains(.close))
    }

    @Test("选中态有参数时两处都出现那个选项按钮，且紧跟马赛克之后")
    func selectedOptionsAppearsInBothContexts() {
        for context in [MarkupToolbarLayout.Context.overlay, .editor] {
            let items = MarkupToolbarLayout.items(
                in: context,
                showsCropTool: context == .editor,
                hasSelectedAnnotationOptions: true
            )
            #expect(items.contains(.selectedOptions))
            let pixelateIndex = items.firstIndex(of: .tool(.pixelate))
            let selectedIndex = items.firstIndex(of: .selectedOptions)
            #expect(pixelateIndex != nil)
            #expect(selectedIndex == pixelateIndex.map { $0 + 1 })
        }
    }

    @Test("输出组五项固定顺序：撤销 / 重做 / 复制 / 保存 / 贴图")
    func actionOrderIsStable() {
        for context in [MarkupToolbarLayout.Context.overlay, .editor] {
            let items = MarkupToolbarLayout.outputItems(in: context)
            let expected = MarkupToolbarLayout.actionCluster.filter {
                $0 != .close || context == .overlay
            }
            #expect(items == expected)
        }
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
