import Foundation

/// 当前进程是不是**自动化环境**（进程内单测 / UI 测试启动的 App 都算）。
///
/// 为什么要有这一层：
/// - 单测进程里能用 `XCTestConfigurationFilePath` 判断；
/// - 但 UI 测试用 `XCUIApplication().launch()` 启动的是**真实的 App 进程**，
///   它不继承那个变量。App 于是以为自己是被用户正常启动的，会弹欢迎框、
///   注册全局快捷键，干扰无人值守跑门禁。
///
/// 所以判定按「**任一**线索命中即算自动化」，并且优先信任我们自己的显式开关
/// `ICESHOT_DISABLE_AUTOMATION`（由 `IceShotUITests` 在 `launchEnvironment` 里注入）。
enum TestEnvironment {

    /// 显式关闭开关：测试侧注入，也可用于本机「按量产行为跑一次」的手动验证。
    nonisolated static let disableAutomationKey = "ICESHOT_DISABLE_AUTOMATION"

    /// 判定所需的线索全部做成参数，便于单测——不需要真的跑在测试环境里。
    ///
    /// `nonisolated`：它只读 `ProcessInfo` / `Bundle`，没有任何共享状态，
    /// 需要从任意线程调用。
    nonisolated static func isAutomation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executablePath: String = Bundle.main.executablePath ?? "",
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        // 1. 我们自己的开关（UI 测试注入，最可靠）。
        if environment[disableAutomationKey] == "1" { return true }

        // 2. 进程内单测：Swift Testing / XCTest 都会注入其中之一。
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        where environment[key] != nil {
            return true
        }

        // 3. 测试运行器本体（`.xctrunner` / `-Runner.app`）及其启动的 App。
        if executablePath.contains(".xctrunner") { return true }
        if executablePath.contains("-Runner.app") { return true }
        if let bundleIdentifier, bundleIdentifier.hasSuffix(".xctrunner") { return true }

        // 4. 启动参数里带 XCTest 注入项。
        if arguments.contains(where: { $0.hasPrefix("-XCTest") || $0 == "-testing" }) {
            return true
        }

        return false
    }
}
