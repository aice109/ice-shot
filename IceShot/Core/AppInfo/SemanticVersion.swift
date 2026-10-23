import Foundation

/// 三段数字版本，用于和 GitHub Release 的 tag 做比较。
///
/// 只认 `major.minor.patch` 三段数字：tag 里的 `v` / `V` 前缀和第一个 `-` 之后的
/// 一切（`-beta.1`、将来的 `-rc.1`）都会被剥掉。理由是发布通道已经由
/// `ReleaseChannel` 单独表达，版本比较不该再把预发布标记掺进来。
///
/// 解析失败返回 `nil` 而不是抛错：调用侧拿到 `nil` 自然当作「无法判断」，
/// 也就是「没有新版本」，不会因为一个畸形 tag 误弹更新提示。
struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// `"v0.3.1-beta.1"` → `0.3.1`；`"1.0"` → `nil`（必须三段）。
    ///
    /// 标 `nonisolated`：它会作为 `UpdateChecker` 初始化默认值的一部分被求值，
    /// 默认参数在非隔离上下文执行（与 `AppVersion` 的处理一致）。
    nonisolated init?(tag: String) {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        if let dash = text.firstIndex(of: "-") {
            text = String(text[text.startIndex..<dash])
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        // 逐段必须是纯数字；`Int("")` 与 `Int("0a")` 都会失败，正好排除畸形输入。
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else {
            return nil
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    /// 直接用当前构建的 `CFBundleShortVersionString` 构造，省得调用侧到处拼 `"v"`。
    nonisolated static var current: SemanticVersion? {
        SemanticVersion(tag: AppVersion.shortVersion)
    }

    nonisolated static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    /// `0.3.1`，用于弹窗标题。
    nonisolated var displayText: String {
        "\(major).\(minor).\(patch)"
    }
}
