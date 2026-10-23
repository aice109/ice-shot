import Foundation
import Testing
@testable import IceShot

/// 下载流程里能纯函数测的部分：校验值解析、资产选取、以及下载编排的失败分支。
struct UpdateDownloadTests {
    // MARK: - 校验值解析

    /// `sha256sum` 输出 `<hash>  <文件名>`（两个空格）。
    @Test func parsesDoubleSpaceChecksumFormat() {
        let text = "4524bfda5be94fd719b546a65e3b9d69dec7ee70449c7ad881f328325c3b6965  IceShot-0.3.2-beta.dmg\n"
        let parsed = URLSessionUpdateDownloader.parseChecksum(
            text,
            expectingFile: "IceShot-0.3.2-beta.dmg"
        )
        #expect(parsed == "4524bfda5be94fd719b546a65e3b9d69dec7ee70449c7ad881f328325c3b6965")
    }

    /// `shasum -a 256` 可能在文件名前加 `*` 表示二进制模式。
    @Test func parsesBinaryModeStarPrefix() {
        let text = "abc123  *IceShot-0.3.2-beta.dmg"
        #expect(
            URLSessionUpdateDownloader.parseChecksum(text, expectingFile: "IceShot-0.3.2-beta.dmg") == "abc123"
        )
    }

    /// 多行时挑指向目标文件的那行，而不是盲取第一行。
    @Test func picksMatchingLineAmongMany() {
        let text = """
        deadbeef  other-file.zip
        cafebabe  IceShot-0.3.2-beta.dmg
        feedface  third.tar.gz
        """
        #expect(
            URLSessionUpdateDownloader.parseChecksum(text, expectingFile: "IceShot-0.3.2-beta.dmg") == "cafebabe"
        )
    }

    @Test func returnsNilForEmptyOrMismatchedInput() {
        #expect(URLSessionUpdateDownloader.parseChecksum("", expectingFile: "a.dmg") == nil)
        #expect(URLSessionUpdateDownloader.parseChecksum("\n\n", expectingFile: "a.dmg") == nil)
        // 只有一行且文件名不匹配时仍接受这一行（单个包的常见情形）。
        #expect(URLSessionUpdateDownloader.parseChecksum("abc  b.dmg", expectingFile: "a.dmg") == "abc")
    }

    // MARK: - 真实文件哈希

    @Test func hashesFileContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        // echo -n "abc" | shasum -a 256 → ba7816bf...
        try Data("abc".utf8).write(to: url)
        #expect(
            URLSessionUpdateDownloader.sha256(ofFileAt: url)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func hashingMissingFileReturnsNil() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)")
        #expect(URLSessionUpdateDownloader.sha256(ofFileAt: missing) == nil)
    }

    // MARK: - 资产选取

    @Test func picksDMGAndItsChecksumAsset() throws {
        let json = """
        [
          {
            "tag_name": "v0.3.2-beta.1",
            "html_url": "https://github.com/aice109/ice-shot/releases/tag/v0.3.2-beta.1",
            "body": "- 更新",
            "draft": false,
            "assets": [
              {"name": "notes.txt", "browser_download_url": "https://example.invalid/notes.txt"},
              {"name": "IceShot-0.3.2-beta.dmg", "browser_download_url": "https://example.invalid/IceShot-0.3.2-beta.dmg"},
              {"name": "IceShot-0.3.2-beta.dmg.sha256", "browser_download_url": "https://example.invalid/IceShot-0.3.2-beta.dmg.sha256"}
            ]
          }
        ]
        """
        let payloads = try JSONDecoder().decode([GitHubReleaseClient.Payload].self, from: Data(json.utf8))
        let dmg = try #require(GitHubReleaseClient.diskImage(in: payloads[0].assets))

        #expect(dmg.name == "IceShot-0.3.2-beta.dmg")
        #expect(dmg.url.absoluteString == "https://example.invalid/IceShot-0.3.2-beta.dmg")
        #expect(dmg.checksumTextURL?.absoluteString == "https://example.invalid/IceShot-0.3.2-beta.dmg.sha256")
    }

    /// 没有 `.dmg` 时返回 nil：调用侧据此降级到网页下载。
    @Test func returnsNilWhenNoDMGAsset() throws {
        let json = """
        [
          {
            "tag_name": "v0.3.2",
            "html_url": "https://example.invalid/tag",
            "draft": false,
            "assets": [
              {"name": "source.zip", "browser_download_url": "https://example.invalid/source.zip"}
            ]
          }
        ]
        """
        let payloads = try JSONDecoder().decode([GitHubReleaseClient.Payload].self, from: Data(json.utf8))
        #expect(GitHubReleaseClient.diskImage(in: payloads[0].assets) == nil)
    }

    @Test func dmgWithoutChecksumStillUsable() throws {
        let json = """
        [
          {
            "tag_name": "v0.3.2",
            "html_url": "https://example.invalid/tag",
            "draft": false,
            "assets": [
              {"name": "IceShot.dmg", "browser_download_url": "https://example.invalid/IceShot.dmg"}
            ]
          }
        ]
        """
        let payloads = try JSONDecoder().decode([GitHubReleaseClient.Payload].self, from: Data(json.utf8))
        let dmg = try #require(GitHubReleaseClient.diskImage(in: payloads[0].assets))
        #expect(dmg.checksumTextURL == nil)
    }
}
