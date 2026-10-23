import Foundation
import Testing
@testable import IceShot

/// 工具分组：工具栏与操作条按组排布，分组规则必须覆盖全部工具且不改变既有顺序。
@MainActor
struct EditorToolGroupTests {
    @Test("两组拼起来正好等于 allCases，顺序不变")
    func groupsPartitionAllCasesInOrder() {
        let combined = EditorTool.tools(in: .drawing) + EditorTool.tools(in: .enhancement)
        #expect(combined == EditorTool.allCases)
    }

    @Test("每个工具只属于一个组")
    func everyToolBelongsToExactlyOneGroup() {
        let drawing = Set(EditorTool.tools(in: .drawing))
        let enhancement = Set(EditorTool.tools(in: .enhancement))
        #expect(drawing.isDisjoint(with: enhancement))
        #expect(drawing.union(enhancement) == Set(EditorTool.allCases))
    }

    @Test("选择与裁剪属于绘制组")
    func selectAndCropAreDrawingTools() {
        #expect(EditorTool.select.group == .drawing)
        #expect(EditorTool.crop.group == .drawing)
        #expect(EditorTool.tools(in: .drawing).contains(.crop))
    }

    @Test("分组过滤保持 allCases 的相对顺序")
    func groupOrderFollowsAllCases() {
        let drawing = EditorTool.tools(in: .drawing)
        let expected = EditorTool.allCases.filter { $0.group == .drawing }
        #expect(drawing == expected)
    }

    @Test("快捷键唯一且都是单个小写字母")
    func shortcutsAreUnique() {
        let shortcuts = EditorTool.allCases.compactMap(\.shortcut)
        #expect(shortcuts.count == EditorTool.allCases.count)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(shortcuts.allSatisfy { $0.isLowercase && $0.isLetter })
    }
}
