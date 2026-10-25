import Foundation
import Testing
@testable import IceShot

/// 对外链接。
///
/// 这两个地址写错的表现很隐蔽：`URL(string:)!` 不会崩，但用户点开是 404。
/// 所以把「指向哪个仓库 / 哪个页面」钉在测试里，改错时至少测试会红。
struct ProjectLinksTests {

    @Test("仓库首页指向 ice-shot 仓库")
    func repositoryPointsAtRepo() {
        #expect(ProjectLinks.repository.absoluteString == "https://github.com/aice109/ice-shot")
        #expect(ProjectLinks.repository.host() == "github.com")
        #expect(ProjectLinks.repository.scheme == "https")
    }

    @Test("最新发布页用 GitHub 的 /releases/latest 自动解析")
    func latestReleaseUsesLatestPath() {
        #expect(ProjectLinks.latestRelease.absoluteString
            == "https://github.com/aice109/ice-shot/releases/latest")
        #expect(ProjectLinks.latestRelease.host() == "github.com")
    }

    @Test("两个链接同源同仓库，不会指到别处")
    func bothLinksShareRepository() {
        #expect(ProjectLinks.latestRelease.absoluteString
            .hasPrefix(ProjectLinks.repository.absoluteString))
    }
}
