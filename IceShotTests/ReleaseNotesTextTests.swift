import Foundation
import Testing
@testable import IceShot

/// Release 正文的清洗与截断。
///
/// `CHANGELOG.md` 的正文是中文带 `**加粗**`、`### 新增`、`- 条目` 的 Markdown，
/// 原样塞进 `NSAlert` 会显示成一堆星号和井号，所以这些标记必须在展示层剥掉。
struct ReleaseNotesTextTests {
    @Test func stripsHeadingAndBoldMarkers() {
        let markdown = "### 新增\n\n- **更新提示**：发现新版本时提示。"
        let text = ReleaseNotesText.condensed(markdown)
        #expect(text.contains("新增"))
        #expect(text.contains("更新提示"))
        #expect(!text.contains("#"))
        #expect(!text.contains("**"))
    }

    @Test func stripsListAndQuoteMarkers() {
        #expect(ReleaseNotesText.clean("- 第一项") == "第一项")
        #expect(ReleaseNotesText.clean("* 第一项") == "第一项")
        #expect(ReleaseNotesText.clean("+ 第一项") == "第一项")
        #expect(ReleaseNotesText.clean("1. 第一项") == "第一项")
        #expect(ReleaseNotesText.clean("> 引用") == "引用")
    }

    @Test func stripsInlineCodeAndItalics() {
        #expect(ReleaseNotesText.clean("运行 `Scripts/gate.sh`") == "运行 Scripts/gate.sh")
        #expect(ReleaseNotesText.clean("这是 *斜体* 文字") == "这是 斜体 文字")
    }

    /// 弹窗里出现长 URL 很难看，链接只保留文字。
    @Test func keepsLinkTextDropsURL() {
        let text = ReleaseNotesText.clean("见 [发布页](https://github.com/aice109/ice-shot/releases)")
        #expect(text == "见 发布页")
    }

    @Test func collapsesBlankLines() {
        let text = ReleaseNotesText.clean("第一段\n\n\n\n第二段")
        #expect(text == "第一段\n第二段")
    }

    @Test func truncatesByLineCount() {
        let manyLines = (1...20).map { "第 \($0) 行" }.joined(separator: "\n")
        let text = ReleaseNotesText.condensed(manyLines)
        let lines = text.components(separatedBy: "\n")

        #expect(text.contains("第 1 行"))
        #expect(text.contains("第 8 行"))
        #expect(!text.contains("第 9 行"))
        #expect(text.hasSuffix(ReleaseNotesText.truncationSuffix))
        #expect(lines.count == ReleaseNotesText.maxLines + 1) // 8 行 + 指路句
    }

    @Test func truncatesByCharacterCount() {
        let longLine = String(repeating: "长", count: 500)
        let text = ReleaseNotesText.condensed(longLine)
        #expect(text.hasSuffix(ReleaseNotesText.truncationSuffix))
        #expect(text.count < 500)
    }

    @Test func shortNotesAreNotTruncated() {
        let text = ReleaseNotesText.condensed("- 只改了一行")
        #expect(text == "只改了一行")
        #expect(!text.contains(ReleaseNotesText.truncationSuffix))
    }

    @Test func emptyInputStaysEmpty() {
        #expect(ReleaseNotesText.condensed("") == "")
        #expect(ReleaseNotesText.condensed("\n\n\n") == "")
        #expect(ReleaseNotesText.condensed("###") == "")
    }
}
