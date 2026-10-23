import Foundation

/// 把 Release 正文（Markdown）压成能塞进 `NSAlert.informativeText` 的短文本。
///
/// 为什么需要清洗：`CHANGELOG.md` 的正文带 `**加粗**`、`### 新增`、`- 条目` 这类标记，
/// 原样放进弹窗会显示成一堆星号和井号。这里只做**展示层的最小修饰剥离**，
/// 不追求完整的 Markdown 解析——弹窗只有几行，够用即可。
///
/// 完整更新日志不在这里呈现：正文末尾统一指向下载页，让想看全的人去网页看。
enum ReleaseNotesText {
    /// 保留的行数上限。
    static let maxLines = 8
    /// 保留的字符数上限（中文按字算，8 行通常远不到这个数）。
    static let maxCharacters = 300
    /// 截断后追加的指路句。
    static let truncationSuffix = "…（完整更新日志见下载页）"

    /// 清洗 + 截断。空输入返回空串，由调用侧决定怎么兜底。
    static func condensed(_ markdown: String) -> String {
        let cleaned = clean(markdown)
        guard !cleaned.isEmpty else { return "" }

        var lines = cleaned.components(separatedBy: .newlines)
        var didTruncate = false

        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            didTruncate = true
        }

        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
            didTruncate = true
        }

        return didTruncate ? text + "\n" + truncationSuffix : text
    }

    /// 剥离展示层标记，并把连续空行压成一行。
    static func clean(_ markdown: String) -> String {
        let stripped = markdown
            .components(separatedBy: .newlines)
            .map { cleanLine($0) }
            .filter { !$0.isEmpty }
        return stripped.joined(separator: "\n")
    }

    private static func cleanLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)

        // 行首的标题井号、引用箭头、列表符号（含 `*` / `+` / 有序列表 `1.`）。
        while let first = text.first, first == "#" || first == ">" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if let first = text.first, first == "-" || first == "*" || first == "+" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        } else if let ordered = dropOrderedListMarker(text) {
            text = ordered
        }

        // 成对的行内标记：粗体、斜体、行内代码。分隔线 `---` 会在这里被剥成空串。
        for token in ["**", "__", "`", "*", "_"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // 链接 `[文字](地址)` 只留文字，避免弹窗里出现长 URL。
        text = stripLinkTargets(text)

        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `"1. 条目"` → `"条目"`；不是有序列表则返回 `nil`。
    private static func dropOrderedListMarker(_ text: String) -> String? {
        var digits = 0
        for character in text {
            if character.isNumber {
                digits += 1
            } else {
                break
            }
        }
        guard digits > 0, digits < text.count else { return nil }
        let markerEnd = text.index(text.startIndex, offsetBy: digits)
        guard text[markerEnd] == "." else { return nil }
        return String(text[text.index(after: markerEnd)...])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stripLinkTargets(_ text: String) -> String {
        var result = ""
        var remainder = Substring(text)

        while let open = remainder.firstIndex(of: "[") {
            result += remainder[remainder.startIndex..<open]

            guard let close = remainder[open...].firstIndex(of: "]"),
                  let parenOpen = remainder.index(close, offsetBy: 1, limitedBy: remainder.endIndex),
                  parenOpen < remainder.endIndex,
                  remainder[parenOpen] == "(",
                  let parenClose = remainder[parenOpen...].firstIndex(of: ")")
            else {
                // 不是标准链接语法：原样保留 `[`，继续往后找。
                result += remainder[open...]
                return result
            }

            result += remainder[remainder.index(after: open)..<close]
            remainder = remainder[remainder.index(after: parenClose)...]
        }

        result += remainder
        return result
    }
}
