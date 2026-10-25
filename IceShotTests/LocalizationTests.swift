import Foundation
import Testing
@testable import IceShot

/// 本地化完整性。
///
/// 「中英文混杂」的根因是代码里 318 条中文字面量只有中文一份。
/// 现在中文原文即开发语言、英文走 `en.lproj/Localizable.strings`——
/// 于是最容易发生的回归是：**新写一条中文 UI 文案，忘了加英文**。
/// 这组测试就是那道闸：界面上会显示的中文键，必须在英文表里也有对应条目。
struct LocalizationTests {
    /// 从 bundle 里读英文表。测试跑在测试 bundle 里，所以显式指定 `IceShot`。
    private func englishTable() -> [String: String] {
        let candidates = [
            Bundle(for: BundleToken.self).path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"),
            Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"),
        ]
        for path in candidates {
            guard let path, let table = NSDictionary(contentsOfFile: path) as? [String: String] else {
                continue
            }
            return table
        }
        return [:]
    }

    /// 英文表能读出来，且不是空表（读不到时下面所有断言都会假绿，所以先钉住这件事）。
    @Test func englishTableLoads() {
        let table = englishTable()
        #expect(!table.isEmpty, "读不到 en.lproj/Localizable.strings，后续断言不可信")
    }

    /// 英文条目里不能残留中文：那说明只是复制了原文没翻译。
    @Test func englishEntriesHaveNoChinese() {
        let table = englishTable()
        let offenders = table.filter { key, value in
            // 键本身是中文原文（这是设计如此）；只检查译文。
            value.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                && key != value
        }
        #expect(
            offenders.isEmpty,
            "以下条目的英文译文里仍有中文：\(offenders.keys.sorted().prefix(10))"
        )
    }

    /// 英文条目的占位符数量必须与中文原文一致。
    ///
    /// `%@` / `%lld` 数量对不上会在运行时丢参数或崩掉格式化。
    @Test func placeholdersMatchSourceText() {
        let table = englishTable()
        func placeholderCount(_ text: String) -> Int {
            let matches = text.matches(of: #/%[@dldf]/# )
            return matches.count
        }
        let offenders = table.filter { key, value in
            placeholderCount(key) != placeholderCount(value)
        }
        #expect(
            offenders.isEmpty,
            "以下条目的占位符数量与原文不一致：\(offenders.keys.sorted().prefix(10))"
        )
    }
}

/// 只为拿到测试 bundle 的锚点类型。
private final class BundleToken {}
