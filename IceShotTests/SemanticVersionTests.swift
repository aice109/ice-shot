import Foundation
import Testing
@testable import IceShot

/// tag 解析与版本比较。
///
/// 比较逻辑最容易出的错是「按字符串比」——`"0.9.9" > "0.10.0"` 在字符串序下成立，
/// 但版本号里 0.10 比 0.9 新。这里逐条钉住。
struct SemanticVersionTests {
    @Test func parsesPlainThreePartVersion() {
        let version = SemanticVersion(tag: "0.3.1")
        #expect(version?.major == 0)
        #expect(version?.minor == 3)
        #expect(version?.patch == 1)
    }

    @Test func stripsLeadingV() {
        #expect(SemanticVersion(tag: "v1.2.3") == SemanticVersion(tag: "1.2.3"))
        #expect(SemanticVersion(tag: "V1.2.3") == SemanticVersion(tag: "1.2.3"))
    }

    /// 发布通道由 `ReleaseChannel` 单独表达，版本比较不该被预发布标记干扰。
    @Test func stripsPrereleaseSuffix() {
        #expect(SemanticVersion(tag: "v0.3.1-beta.1")?.displayText == "0.3.1")
        #expect(SemanticVersion(tag: "v0.3.1-rc.2")?.displayText == "0.3.1")
        #expect(SemanticVersion(tag: "0.3.1-beta.1") == SemanticVersion(tag: "0.3.1"))
    }

    @Test func comparesNumericallyNotLexically() {
        let newer = SemanticVersion(tag: "0.10.0")
        let older = SemanticVersion(tag: "0.9.9")
        #expect(newer != nil && older != nil)
        if let newer, let older {
            #expect(newer > older)
            #expect(!(older > newer))
        }
    }

    @Test func comparesEachComponentInOrder() {
        #expect(SemanticVersion(tag: "1.0.0")! > SemanticVersion(tag: "0.99.99")!)
        #expect(SemanticVersion(tag: "0.2.0")! > SemanticVersion(tag: "0.1.99")!)
        #expect(SemanticVersion(tag: "0.1.2")! > SemanticVersion(tag: "0.1.1")!)
        #expect(SemanticVersion(tag: "0.1.1")! == SemanticVersion(tag: "0.1.1")!)
    }

    /// 畸形 tag 返回 nil，调用侧当作「无法判断」，不会误报有新版。
    @Test func rejectsMalformedTags() {
        #expect(SemanticVersion(tag: "") == nil)
        #expect(SemanticVersion(tag: "v") == nil)
        #expect(SemanticVersion(tag: "1.0") == nil)     // 只有两段
        #expect(SemanticVersion(tag: "1.0.0.0") == nil)
        #expect(SemanticVersion(tag: "a.b.c") == nil)
        #expect(SemanticVersion(tag: "1.0.x") == nil)
        #expect(SemanticVersion(tag: "beta") == nil)
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(SemanticVersion(tag: "  v0.3.1\n") == SemanticVersion(tag: "0.3.1"))
    }

    @Test func displayTextMatchesParsedComponents() {
        #expect(SemanticVersion(tag: "v12.34.56-beta.9")?.displayText == "12.34.56")
    }
}
