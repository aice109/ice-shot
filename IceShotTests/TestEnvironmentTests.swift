import Foundation
import Testing
@testable import IceShot

/// 自动化环境判定。
///
/// UI 测试用 `XCUIApplication().launch()` 启动的是真实 App 进程，
/// 它拿不到进程内单测才有的 `XCTestConfigurationFilePath`，于是会被判成「正常启动」，
/// 弹出欢迎框并注册全局快捷键，干扰无人值守跑门禁。
struct TestEnvironmentTests {
    @Test("没有自动化线索时判为普通启动")
    func plainLaunchIsNotAutomation() {
        #expect(!TestEnvironment.isAutomation(
            environment: [:],
            bundleIdentifier: "com.aice109.IceShot",
            executablePath: "/Applications/IceShot.app/Contents/MacOS/IceShot",
            arguments: ["/Applications/IceShot.app/Contents/MacOS/IceShot"]
        ))
    }

    @Test("UI 测试注入的显式开关必须生效")
    func explicitSwitchDisablesAutomation() {
        #expect(TestEnvironment.isAutomation(
            environment: [TestEnvironment.disableAutomationKey: "1"]
        ))
    }

    @Test("进程内单测的三种标记都能识别")
    func inProcessTestMarkers() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(
                TestEnvironment.isAutomation(environment: [key: "/tmp/x.xctest"]),
                "\(key) 应当被判为自动化环境"
            )
        }
    }

    @Test("测试运行器本体及其启动的 App")
    func testRunnerExecutables() {
        #expect(TestEnvironment.isAutomation(
            environment: [:],
            bundleIdentifier: "com.aice109.IceShotUITests.xctrunner",
            executablePath: ""
        ))
        #expect(TestEnvironment.isAutomation(
            environment: [:],
            executablePath: "/tmp/IceShotUITests-Runner.app/Contents/MacOS/IceShotUITests-Runner"
        ))
    }

    @Test("启动参数里的 XCTest 注入项")
    func xctestLaunchArguments() {
        #expect(TestEnvironment.isAutomation(
            environment: [:],
            arguments: ["/path/app", "-XCTest"]
        ))
        #expect(TestEnvironment.isAutomation(
            environment: [:],
            arguments: ["/path/app", "-testing"]
        ))
    }

    @Test("开关值必须是 \"1\"，别的值不生效")
    func switchRequiresExactValue() {
        #expect(!TestEnvironment.isAutomation(
            environment: [TestEnvironment.disableAutomationKey: "0"],
            bundleIdentifier: "com.aice109.IceShot",
            executablePath: "/Applications/IceShot.app/Contents/MacOS/IceShot",
            arguments: []
        ))
    }
}
