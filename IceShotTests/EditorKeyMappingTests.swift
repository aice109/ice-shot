import AppKit
import Testing
@testable import IceShot

/// 编辑器里「⌫」和「⌘⌫」是两个不同动作，共用同一个 keyCode。
///
/// 这组用例锁的就是这个容易写反的地方：带 command 的退格必须落到「删这张截图」，
/// 裸退格落到「删选中标注」；判次序错了，删除入口会静默失效（被删标注那条吞掉）。
struct EditorKeyMappingTests {
    private let backspace: UInt16 = 51
    private let forwardDelete: UInt16 = 117

    @Test("裸退格删选中标注")
    func plainBackspaceDeletesAnnotation() {
        #expect(EditorKeyMapping.command(forKeyCode: backspace, modifiers: [])
            == .deleteSelectedAnnotation)
        #expect(EditorKeyMapping.command(forKeyCode: forwardDelete, modifiers: [])
            == .deleteSelectedAnnotation)
    }

    @Test("⌘⌫ 删除这张截图")
    func commandBackspaceDeletesScreenshot() {
        #expect(EditorKeyMapping.command(forKeyCode: backspace, modifiers: [.command])
            == .deleteScreenshot)
        #expect(EditorKeyMapping.command(forKeyCode: forwardDelete, modifiers: [.command])
            == .deleteScreenshot)
    }

    @Test("带其它修饰键时仍是删截图，不会退化成删标注")
    func otherModifiersDoNotFallBack() {
        #expect(EditorKeyMapping.command(forKeyCode: backspace, modifiers: [.command, .shift])
            == .deleteScreenshot)
    }

    @Test("其它键不归这里管")
    func nonDeleteKeysAreIgnored() {
        #expect(EditorKeyMapping.command(forKeyCode: 53, modifiers: [.command]) == nil)
        #expect(EditorKeyMapping.command(forKeyCode: 36, modifiers: []) == nil)
    }
}
