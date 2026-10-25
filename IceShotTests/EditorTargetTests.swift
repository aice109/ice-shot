import Foundation
import Testing
@testable import IceShot

/// 编辑器删除能力的前提：「这次编辑的图能不能删、删的是哪条记录」只由来源决定。
///
/// 这些用例锁三件事：
/// 1. 截图 / 长截图直胀的编辑器永远不出现删除入口（记录还没落库，删起来会和写入抢时序）；
/// 2. 收藏的图不能删（历史清理本就豁免收藏，两处语义必须一致）；
/// 3. 删除按钮的提示文案在每种状态下都说清「为什么点不动」。
struct EditorTargetTests {
    private let recordID = UUID()

    @Test("截图直胀编辑器没有删除入口")
    func standaloneHasNoDelete() {
        let target = EditorTarget.standalone
        #expect(target.showsDelete == false)
        #expect(target.allowsDelete == false)
        #expect(target.recordID == nil)
    }

    @Test("历史来源可以删除")
    func historyAllowsDelete() {
        let target = EditorTarget.history(recordID: recordID, isFavorite: false)
        #expect(target.showsDelete)
        #expect(target.allowsDelete)
        #expect(target.recordID == recordID)
    }

    @Test("收藏的图不允许删除，但仍带上记录 ID")
    func favoriteHistoryDisallowsDelete() {
        let target = EditorTarget.history(recordID: recordID, isFavorite: true)
        #expect(target.allowsDelete == false)
        // recordID 仍要保留：将来做「先取消收藏再删除」时不用重新传一遍身份。
        #expect(target.recordID == recordID)
    }

    @Test("收藏态的提示说清要先取消收藏")
    func favoriteHelpExplainsWhy() {
        let help = EditorTarget.history(recordID: recordID, isFavorite: true).deleteHelp
        // 断言完整文案，而不是半截词：英文表里只有整句的对应条目。
        #expect(help == String(localized: "已收藏的截图不会被自动清理，请先取消收藏再删除"))
    }

    @Test("可删状态把快捷键写进提示")
    func deletableHelpMentionsShortcut() {
        let help = EditorTarget.history(recordID: recordID, isFavorite: false).deleteHelp
        #expect(help.contains("⌘⌫"))
    }
}
