import Foundation
import Testing
@testable import IceShot

@MainActor
struct LaunchAtLoginTests {
    /// 测试替身：不碰真实的 `SMAppService`，只记录调用并模拟系统状态变化。
    final class FakeService: LaunchAtLoginServicing {
        var state: LaunchAtLoginState
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        private(set) var openedSystemSettings = false

        init(state: LaunchAtLoginState = .disabled) {
            self.state = state
        }

        func register() throws {
            registerCount += 1
            if let registerError {
                throw registerError
            }
            state = .enabled
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisterError {
                throw unregisterError
            }
            state = .disabled
        }

        func openSystemSettings() {
            openedSystemSettings = true
        }
    }

    private struct FakeError: LocalizedError {
        var errorDescription: String? { "系统拒绝了这次注册" }
    }

    @Test func initializesFromSystemState() {
        #expect(LaunchAtLoginModel(service: FakeService(state: .enabled)).isEnabled)
        #expect(!LaunchAtLoginModel(service: FakeService(state: .disabled)).isEnabled)
        // 「待批准」不是开启：开关要显示为关，否则用户会以为已经生效。
        #expect(!LaunchAtLoginModel(service: FakeService(state: .requiresApproval)).isEnabled)
    }

    @Test func enablingRegistersAndReadsBackSystemState() {
        let service = FakeService()
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        #expect(service.registerCount == 1)
        #expect(model.isEnabled)
        #expect(model.failureMessage == nil)
    }

    @Test func disablingUnregisters() {
        let service = FakeService(state: .enabled)
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(!model.isEnabled)
    }

    @Test func registerFailureRollsToggleBackAndReportsReason() {
        let service = FakeService()
        service.registerError = FakeError()
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        // 失败后不能显示为已开启：开关回滚，原因交给界面。
        #expect(!model.isEnabled)
        #expect(service.state == .disabled)
        // 失败文案里带了系统错误描述与错误码（运行时拼出来），所以这里只验
        // 「确实有失败提示」且「带上了自己的前缀」，不钉死整句。
        #expect(model.failureMessage?.contains("设置开机自启动失败") == true)
    }

    @Test func unregisterFailureKeepsToggleOn() {
        let service = FakeService(state: .enabled)
        service.unregisterError = FakeError()
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(false)

        #expect(model.isEnabled)
        #expect(model.failureMessage != nil)
    }

    @Test func requiresApprovalShowsHintAndSettingsButton() {
        let model = LaunchAtLoginModel(service: FakeService(state: .requiresApproval))

        #expect(
            model.systemHint
                == String(localized: "系统里这个登录项被关掉了：到「系统设置 > 通用 > 登录项」重新打开 IceShot。")
        )
        #expect(model.showsSystemSettingsButton)
    }

    /// 回归：0.2.1 把 `.notFound`（= 从未注册过）当成「App 不见了」，
    /// 全新安装打开设置页就会弹「先把 IceShot 放进应用程序文件夹」。
    @Test func firstRunStateIsQuietAndStillEnables() {
        let service = FakeService(state: .disabled)
        let model = LaunchAtLoginModel(service: service, bundlePath: "/Applications/IceShot.app")

        #expect(!model.isEnabled)
        #expect(model.systemHint == nil)
        #expect(model.locationHint == nil)
        #expect(!model.showsSystemSettingsButton)

        model.setEnabled(true)
        #expect(service.registerCount == 1)
        #expect(model.isEnabled)
    }

    @Test func translocatedCopyExplainsHowToFix() {
        let model = LaunchAtLoginModel(
            service: FakeService(),
            bundlePath: "/private/var/folders/xy/AppTranslocation/ABC/d/IceShot.app"
        )

        // 断言完整文案：这些提示都是单条本地化字符串，
        // 用 `contains("应用程序")` 这种半截词在英文表里根本没有对应条目。
        #expect(
            model.locationHint
                == String(localized: "当前是从下载目录直接打开的临时副本：先把 IceShot 拖到「应用程序」再打开，才能注册登录项。")
        )
    }

    @Test func copyRunningFromDiskImageExplainsHowToFix() {
        let model = LaunchAtLoginModel(
            service: FakeService(),
            bundlePath: "/Volumes/IceShot/IceShot.app"
        )

        #expect(
            model.locationHint
                == String(localized: "当前正在从磁盘映像里运行：先把 IceShot 拖到「应用程序」再打开，才能注册登录项。")
        )
    }

    @Test func installedAppHasNoLocationHint() {
        let model = LaunchAtLoginModel(
            service: FakeService(),
            bundlePath: "/Applications/IceShot.app"
        )

        #expect(model.locationHint == nil)
    }

    @Test func enabledStateHasNoHintOrSettingsButton() {
        let model = LaunchAtLoginModel(service: FakeService(state: .enabled))

        #expect(model.systemHint == nil)
        #expect(!model.showsSystemSettingsButton)
    }

    @Test func refreshPicksUpExternalSystemChanges() {
        let service = FakeService()
        let model = LaunchAtLoginModel(service: service)
        #expect(!model.isEnabled)

        // 模拟用户在「系统设置 > 登录项」里手动打开。
        service.state = .enabled
        model.refresh()

        #expect(model.isEnabled)
    }

    @Test func openSystemSettingsReachesService() {
        let service = FakeService(state: .requiresApproval)
        let model = LaunchAtLoginModel(service: service)

        model.openSystemSettings()

        #expect(service.openedSystemSettings)
    }
}
