import Foundation
import Testing
@testable import IceShot

/// 版本展示与发布通道。
///
/// 版本号本身必须是纯数字（Apple 只接受数字与点），预览标识不能塞进
/// `CFBundleShortVersionString`，所以单独走 `ReleaseChannel`。
struct AppVersionTests {
    @Test func stableChannelHasNoSuffix() {
        #expect(AppVersion.text(version: "0.2.2", build: "4", channel: .stable) == "0.2.2 (4)")
        #expect(ReleaseChannel.stable.tag == nil)
        #expect(!ReleaseChannel.stable.isBeta)
    }

    @Test func betaChannelIsMarked() {
        #expect(AppVersion.text(version: "0.2.2", build: "4", channel: .beta) == "0.2.2 (4) · Beta")
        #expect(ReleaseChannel.beta.tag == "Beta")
        #expect(ReleaseChannel.beta.isBeta)
    }

    /// 版本号本身不能带字母：打包脚本与 App Store 都按纯数字解析。
    @Test func bundleVersionStaysNumeric() {
        let version = AppVersion.shortVersion
        #expect(!version.lowercased().contains("beta"))
        #expect(version.allSatisfy { $0.isNumber || $0 == "." })
    }
}
