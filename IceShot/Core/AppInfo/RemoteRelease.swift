import Foundation

/// 从 GitHub Release 接口取回的、界面真正需要的那几个字段。
///
/// 刻意只保留三项：完整响应有几十个字段，其中 `author`、`assets`、`node_id`
/// 之类对「提示一下然后跳转下载页」毫无用处，留着只会扩大解码失败的面。
struct RemoteRelease: Equatable, Sendable {
    /// `v0.3.2-beta.1` 这样的原始 tag，交给 `SemanticVersion` 解析。
    let tagName: String
    /// 该 Release 的网页地址；「前往下载」直接打开它，保证版本与提示一致。
    let htmlURL: URL
    /// Release 正文（Markdown），由 `ReleaseNotesText` 清洗截断后再展示。
    let notes: String
}
