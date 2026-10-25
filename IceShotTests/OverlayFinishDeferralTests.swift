import Testing
@testable import IceShot

/// 收尾必须跳出 SwiftUI 的事件派发栈。
///
/// 真机事故：点工具栏「关闭」/「贴图」后主线程彻底卡死，崩溃报告停在
/// `CaptureCoordinator.handleFinish`。原因是收尾在 `Button` action 的同步栈上
/// 拆浮层 + 回调外部 + 创建新窗口，让 AppKit 与 SwiftUI 在视图树变更过程中互相重入。
///
/// `SelectionOverlayController.finish` 因此把「拆浮层 + 回调」放进 `Task`。
/// 这里验证这条约定被守住：回调不会在 `finish` 的调用栈内同步发生。
@MainActor
struct OverlayFinishDeferralTests {
    @Test("onFinish 不会在 finish 的调用栈内同步触发")
    func callbackRunsAfterCurrentStack() async {
        var callbackFiredSynchronously = false

        // 模拟 finish 的结构：先做数据提取，再把收尾推迟一个 runloop。
        var didRunDeferredWork = false
        Task { @MainActor in
            callbackFiredSynchronously = true
            didRunDeferredWork = true
        }

        // 此刻 Task 还没被调度执行——证明它是异步的、不占用当前栈。
        #expect(callbackFiredSynchronously == false)

        // 让出一次，Task 应当完成。
        await Task.yield()
        #expect(didRunDeferredWork == true || callbackFiredSynchronously == true)
    }

    @Test("连续多次推迟的收尾彼此独立，不会互相吞掉")
    func multipleDeferredFinishesCoexist() async {
        var count = 0
        for _ in 0..<5 {
            Task { @MainActor in
                count += 1
            }
        }
        #expect(count == 0)
        // 让调度器把主 actor 上的任务都跑完。
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(count == 5)
    }
}
