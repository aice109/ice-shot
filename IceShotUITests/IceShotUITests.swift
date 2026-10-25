//
//  IceShotUITests.swift
//  IceShotUITests
//

import XCTest

/// 最小启动冒烟：确认应用能启动并正常退出。
/// 截图 / 编辑 / 权限等真实交互需要真机手测，不在自动化里重复。
final class IceShotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndQuit() throws {
        let app = XCUIApplication()
        // 必须显式关闭自动化：UI 测试启动的是**真实的 App 进程**，
        // 它拿不到进程内单测才有的 `XCTestConfigurationFilePath`，App 会以为
        // 自己是普通启动，于是联网检查更新并弹出模态框。那个框的默认按钮是
        // 「前往下载」——无人值守跑门禁时会被点到，反复打开 GitHub 发布页
        // （表现就是「每跑一次测试就多开一堆浏览器标签」）。
        app.launchEnvironment["ICESHOT_DISABLE_AUTOMATION"] = "1"
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
        app.terminate()
    }
}
