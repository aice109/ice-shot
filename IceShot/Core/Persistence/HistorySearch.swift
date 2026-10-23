import Foundation

/// 历史列表的搜索匹配规则（纯函数，便于单测）。
///
/// 搜索范围：标签、来源名称、OCR 识别出的文字。三者都是「包含匹配、忽略大小写」，
/// 不做分词与高亮，保持与系统 `.searchable` 一致的直觉。
enum HistorySearch {
    static func matches(record: ScreenshotRecord, query: String) -> Bool {
        matches(
            tags: record.tags,
            sourceName: record.source.displayName,
            ocrText: record.ocrText,
            query: query
        )
    }

    static func matches(
        tags: [String],
        sourceName: String,
        ocrText: String?,
        query: String
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if sourceName.localizedCaseInsensitiveContains(trimmed) {
            return true
        }
        if tags.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) }) {
            return true
        }
        if let ocrText, !ocrText.isEmpty,
           ocrText.localizedCaseInsensitiveContains(trimmed) {
            return true
        }
        return false
    }
}
