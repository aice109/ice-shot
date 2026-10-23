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
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
        app.terminate()
    }
}
