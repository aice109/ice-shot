import Foundation
import Testing
@testable import IceShot

/// 工具分组：操作条按组渲染，一个按钮可能承载多个工具（形状 / 画笔 / 更多）。
///
/// 这些用例锁的是「分组表与实际可画出来的工具一致」——新增工具忘了进表、
/// 同一工具被放进了两个组、组内顺序被无意调换，都会在这里失败。
@MainActor
struct EditorToolGroupTests {
    @Test("三组拼起来覆盖所有可上条的工具，且互不重叠")
    func groupsPartitionToolbarTools() {
        let grouped = EditorTool.ToolGroup.allCases.flatMap(\.members)
        #expect(Set(grouped).count == grouped.count)
        // 组里只装「一个按钮承载多件工具」的那些；选择 / 裁剪 / 箭头 / 文字 / 马赛克
        // 各自独占一格，不在任何组里。
        let expected = Set(EditorTool.allCases)
            .subtracting([.select, .crop, .arrow, .text, .pixelate])
        #expect(Set(grouped) == expected)
    }

    @Test("每个工具最多属于一个组")
    func everyToolBelongsToAtMostOneGroup() {
        for tool in EditorTool.allCases {
            let owners = EditorTool.ToolGroup.allCases.filter { $0.members.contains(tool) }
            #expect(owners.count <= 1)
        }
    }

    @Test("toolGroup 与 members 互为反查")
    func toolGroupMatchesMembers() {
        for group in EditorTool.ToolGroup.allCases {
            for tool in group.members {
                #expect(tool.toolGroup == group)
            }
        }
    }

    @Test("选择 / 裁剪 / 箭头 / 文字 / 马赛克 自己独占一格")
    func standaloneToolsHaveNoGroup() {
        for tool in [EditorTool.crop, .arrow, .text, .pixelate] {
            #expect(tool.toolGroup == nil)
        }
    }

    @Test("组内顺序：形状 矩形→椭圆→直线，画笔 画笔→荧光笔，更多 序号→聚光灯→放大镜")
    func groupMemberOrder() {
        #expect(EditorTool.ToolGroup.shape.members == [.rectangle, .ellipse, .line])
        #expect(EditorTool.ToolGroup.brush.members == [.freehand, .highlighter])
        #expect(EditorTool.ToolGroup.more.members == [.number, .spotlight, .magnifier])
    }

    @Test("形状与画笔组里不能塞裁剪——浮层没有裁剪，会带出一个空组按钮")
    func cropIsNotInAnyGroup() {
        for group in EditorTool.ToolGroup.allCases {
            #expect(!group.members.contains(.crop))
        }
    }

    @Test("快捷键唯一且都是单个小写字母")
    func shortcutsAreUnique() {
        let shortcuts = EditorTool.allCases.compactMap(\.shortcut)
        #expect(shortcuts.count == EditorTool.allCases.count)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(shortcuts.allSatisfy { $0.isLowercase && $0.isLetter })
    }
}
