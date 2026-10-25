import AppKit
import Testing
@testable import IceShot

/// `Esc` 的统一优先级：先退模式（取字 / 二级选项），再关 / 取消截图。
@MainActor
struct EscapeActionTests {
    @Test("取字模式：Esc 只退出取字")
    func textPickingWins() {
        #expect(
            EditorEscapeAction.resolve(isTextPicking: true, hasOptions: false, isEditing: true)
                == .exitTextPicking
        )
        // 取字优先于二级选项浮窗。
        #expect(
            EditorEscapeAction.resolve(isTextPicking: true, hasOptions: true, isEditing: true)
                == .exitTextPicking
        )
    }

    @Test("二级选项浮窗：Esc 先关浮窗")
    func optionsBeatClosing() {
        #expect(
            EditorEscapeAction.resolve(isTextPicking: false, hasOptions: true, isEditing: true)
                == .closeOptions
        )
    }

    @Test("编辑中无模式：Esc 关闭这次编辑")
    func plainEditingCloses() {
        #expect(
            EditorEscapeAction.resolve(isTextPicking: false, hasOptions: false, isEditing: true)
                == .closeEditing
        )
    }

    @Test("还没开始编辑：Esc 取消截图")
    func idleCancels() {
        #expect(
            EditorEscapeAction.resolve(isTextPicking: false, hasOptions: false, isEditing: false)
                == .cancelCapture
        )
    }

    @Test("浮层没进入编辑时按取消处理")
    func resolveWithoutEditor() {
        #expect(EditorEscapeAction.resolve(editor: nil, isEditing: false) == .cancelCapture)
    }

    @Test("同一个 Esc 被多层看到时只处理一次")
    func escapeGateHandlesOncePerKey() {
        var gate = EscapeGate()
        let first = gate.shouldHandle(at: 100)
        #expect(first)
        // 同一按键被另一层看到（毫秒级间隔）不能再动状态。
        let sameKeySecondLayer = gate.shouldHandle(at: 100.005)
        #expect(sameKeySecondLayer == false)
        let sameKeyThirdLayer = gate.shouldHandle(at: 100.02)
        #expect(sameKeyThirdLayer == false)
        // 人手连按两次远大于窗口，仍然要生效。
        let secondPress = gate.shouldHandle(at: 100 + EscapeGate.interval + 0.001)
        #expect(secondPress)
    }

    @Test("取字模式下面板关不掉：系统想关会先退回编辑态")
    func panelRefusesCloseWhileTextPicking() {
        let panel = makePanel()
        var exitedTextPicking = 0
        var cancelRequests = 0
        panel.onTextPickingEscape = {
            exitedTextPicking += 1
            return true
        }
        panel.onCancelOperation = { cancelRequests += 1 }

        // 只有「用户发起的关闭」（Esc / 关窗手势 → `performClose:`）会被拦。
        panel.performClose(nil)

        #expect(exitedTextPicking == 1)
        #expect(cancelRequests == 0)
        // 程序化 `close()` 必须**永远**能关掉：它是控制器拆浮层的唯一出口。
        // 一旦被拦，`.screenSaver` 层级的全屏面板就再没有任何退出路径（旧实现的全屏死锁）。
        panel.close()
        #expect(panel.isVisible == false)
    }

    @Test("非取字模式下关窗请求转成 Esc 语义")
    func panelRoutesCloseToEscapeWhenNotTextPicking() {
        let panel = makePanel()
        var cancelRequests = 0
        panel.onTextPickingEscape = { false }
        panel.onCancelOperation = { cancelRequests += 1 }

        panel.performClose(nil)

        #expect(cancelRequests == 1)
        // `close()` 不走 Esc 语义，否则重复关闭会重入收尾。
        panel.close()
        #expect(cancelRequests == 1)
        #expect(panel.isVisible == false)
    }

    @Test("协调器收尾时允许真正关闭")
    func panelClosesWhenAllowed() {
        let panel = makePanel()
        panel.onCancelOperation = { Issue.record("收尾时不应再走 Esc") }
        panel.allowsClose = true
        panel.close()
        #expect(panel.isVisible == false)
    }

    private func makePanel() -> CaptureOverlayPanel {
        CaptureOverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    @Test("浮层面板不再把 Esc 当成默认关闭")
    func panelRoutesCancelOperationToHandler() {
        let panel = CaptureOverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var handled = 0
        panel.onCancelOperation = { handled += 1 }
        panel.cancelOperation(nil)
        #expect(handled == 1)
        #expect(panel.isVisible == false)
    }

    /// 回归：`allowsClose` 一旦为真（`dismiss()` 已开始收尾），`cancelOperation`
    /// 必须交回 `NSWindow` 默认实现，而不是再跑一遍 Esc 判定 / 再重入收尾。
    @Test("收尾中不再重复路由 Esc")
    func panelIgnoresCancelWhileClosing() {
        let panel = makePanel()
        var handled = 0
        panel.onCancelOperation = { handled += 1 }
        panel.allowsClose = true
        panel.cancelOperation(nil)
        #expect(handled == 0)
    }
}
